defmodule FhirFlBridgeWeb.FhirController do
  use Phoenix.Controller, formats: [:json]

  alias FhirFlBridge.FHIR.{Bridge, Validator}
  alias FhirFlBridge.Repo
  alias FhirFlBridge.Repo.Schemas.ConceptMapping

  import Ecto.Query

  # POST /api/v1/fhir/map
  def map_resource(conn, params) do
    fhir_resource    = Map.get(params, "resource", params)
    municipality_code = Map.get(params, "municipality_code", "unknown")

    case Bridge.map_resource_sync(fhir_resource, municipality_code) do
      {:ok, mapping_attrs} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status:               mapping_attrs.status,
          confidence_score:     mapping_attrs.confidence_score,
          lucene_score:         mapping_attrs.lucene_score,
          canonical_concept_id: mapping_attrs.canonical_concept_id,
          fhir_coding:          mapping_attrs.fhir_coding,
          requires_human_review: mapping_attrs.requires_human_review,
          municipality_code:    municipality_code
        })

      {:error, {:invalid_fhir, msg}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_fhir_resource", message: msg})

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "mapping_failed", details: inspect(reason)})
    end
  end

  # GET /api/v1/fhir/mappings
  def list_mappings(conn, params) do
    status_filter       = Map.get(params, "status")
    municipality_filter = Map.get(params, "municipality_code")

    query = from cm in ConceptMapping, order_by: [desc: cm.mapped_at]

    query = if status_filter,
      do: where(query, [cm], cm.status == ^status_filter), else: query

    query = if municipality_filter,
      do: where(query, [cm], cm.municipality_code == ^municipality_filter), else: query

    mappings = Repo.all(query)

    conn
    |> put_status(:ok)
    |> json(%{total: length(mappings), mappings: Enum.map(mappings, &mapping_to_json/1)})
  end

  # GET /api/v1/fhir/mappings/:id
  def show_mapping(conn, %{"id" => id}) do
    case Repo.get(ConceptMapping, id) do
      nil     -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      mapping -> conn |> put_status(:ok) |> json(mapping_to_json(mapping))
    end
  end

  # PATCH /api/v1/fhir/mappings/:id/review
  def review_mapping(conn, %{"id" => id} = params) do
    decision    = Map.get(params, "decision")
    reviewed_by = Map.get(params, "reviewed_by", "unknown")

    case Repo.get(ConceptMapping, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      mapping ->
        new_status = case decision do
          "approve" -> "auto_accepted"
          "reject"  -> "rejected"
          _         -> "pending_review"
        end

        {:ok, updated} =
          mapping
          |> Ecto.Changeset.change(%{
            status:               new_status,
            reviewed_by:          reviewed_by,
            canonical_concept_id: Map.get(params, "canonical_concept_id", mapping.canonical_concept_id)
          })
          |> Repo.update()

        conn |> put_status(:ok) |> json(mapping_to_json(updated))
    end
  end

  # GET /api/v1/fhir/thresholds
  def thresholds(conn, _params) do
    t = Validator.current_thresholds()

    conn
    |> put_status(:ok)
    |> json(%{
      thresholds: t,
      description: %{
        auto_accept:  "score >= #{t.auto_accept} → aceito automaticamente",
        pending:      "#{t.review_floor} <= score < #{t.auto_accept} → fila do Guardião",
        rejected:     "score < #{t.review_floor} → bloqueado até revisão humana"
      }
    })
  end

  defp mapping_to_json(m) do
    %{
      id:                   m.id,
      original_code:        m.original_code,
      original_system:      m.original_system,
      canonical_concept_id: m.canonical_concept_id,
      confidence_score:     m.confidence_score,
      lucene_score:         m.lucene_score,
      status:               m.status,
      reviewed_by:          m.reviewed_by,
      municipality_code:    m.municipality_code,
      fhir_resource_type:   m.fhir_resource_type,
      mapped_at:            format_dt(m.mapped_at)
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end

# =============================================================================

defmodule FhirFlBridgeWeb.FlController do
  use Phoenix.Controller, formats: [:json]

  alias FhirFlBridge.FL.{Orchestrator, RoundWorker}
  alias FhirFlBridge.Repo
  alias FhirFlBridge.Repo.Schemas.{FLRound, FLParticipant}

  import Ecto.Query

  # GET /api/v1/fl/rounds
  def list_rounds(conn, _params) do
    try do
      rounds =
        FLRound
        |> order_by([r], desc: r.inserted_at)
        |> limit(50)
        |> Repo.all()

      conn
      |> put_status(:ok)
      |> json(%{total: length(rounds), rounds: Enum.map(rounds, &round_to_json/1)})
    rescue
      e ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "db_error", details: Exception.message(e)})
    end
  end

  # GET /api/v1/fl/rounds/:id
  def show_round(conn, %{"id" => id}) do
    case Repo.get(FLRound, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      round ->
        participants =
          FLParticipant
          |> where([p], p.fl_round_id == ^id)
          |> Repo.all()

        conn
        |> put_status(:ok)
        |> json(Map.put(round_to_json(round), :participants,
              Enum.map(participants, &participant_to_json/1)))
    end
  end

  # POST /api/v1/fl/rounds
  def start_round(conn, params) do
    participants =
      params
      |> Map.get("participants", [])
      |> Enum.map(fn p ->
        %{
          municipality_code: Map.get(p, "municipality_code"),
          node_url:          Map.get(p, "node_url"),
          confidence_weight: Map.get(p, "confidence_weight", 0.5)
        }
      end)

    case Orchestrator.start_manual_round(participants) do
      {:ok, round_id} ->
        conn
        |> put_status(:created)
        |> json(%{
          round_id: round_id,
          status:   "started",
          message:  "Rodada iniciada. Nós vão treinar e retornar gradientes em ~2s."
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v1/fl/status
  def orchestrator_status(conn, _params) do
    status = Orchestrator.get_status()

    conn
    |> put_status(:ok)
    |> json(%{
      current_model_version: status.current_model_version,
      active_rounds:         length(status.active_round_ids),
      active_round_ids:      status.active_round_ids,
      total_completed:       status.total_rounds_completed,
      last_round_at:         format_dt(status.last_round_at),
      started_at:            format_dt(status.started_at)
    })
  end

  # POST /api/v1/fl/rounds/:id/gradients
  # Chamado automaticamente pelos nós após treinamento local
  def submit_gradients(conn, %{"id" => round_id} = params) do
    municipality_code = Map.get(params, "municipality_code")
    gradients         = Map.get(params, "gradients")

    require Logger

    if is_nil(municipality_code) || is_nil(gradients) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "municipality_code e gradients são obrigatórios"})
    else
      case Registry.lookup(FhirFlBridge.RoundRegistry, round_id) do
        [{pid, _}] ->
          Logger.info("[FlController] Gradientes de #{municipality_code} → rodada #{round_id} (pid=#{inspect(pid)})")
          GenServer.cast(pid, {:gradient_submitted, municipality_code, gradients})

          conn
          |> put_status(:accepted)
          |> json(%{status: "gradients_received", round_id: round_id, municipality_code: municipality_code})

        [] ->
          Logger.warning("[FlController] RoundWorker não encontrado para round_id=#{round_id} — rodada já encerrou?")

          conn
          |> put_status(:accepted)   # ainda retorna 202 para não travar o nó
          |> json(%{status: "round_not_active", round_id: round_id})
      end
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp round_to_json(r) do
    %{
      id:                     r.id,
      status:                 r.status,
      model_version:          r.model_version,
      total_participants:     r.total_participants,
      completed_participants: r.completed_participants,
      aggregation_strategy:   r.aggregation_strategy,
      global_weights:         r.global_weights,
      started_at:             format_dt(r.started_at),
      completed_at:           format_dt(r.completed_at)
    }
  end

  defp participant_to_json(p) do
    %{
      id:                p.id,
      municipality_code: p.municipality_code,
      node_url:          p.node_url,
      confidence_weight: p.confidence_weight,
      status:            p.status,
      samples_count:     p.samples_count,
      submitted_at:      format_dt(p.submitted_at),
      has_gradients:     not is_nil(p.local_gradients)
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_dt(other), do: inspect(other)
end

# =============================================================================

defmodule FhirFlBridgeWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok", service: "fhir-fl-bridge", version: "0.1.0",
              timestamp: DateTime.to_iso8601(DateTime.utc_now())})
  end
end
