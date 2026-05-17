defmodule FhirFlBridge.Lexicon.ClientBehaviour do
  @moduledoc """
  Behaviour que define o contrato do cliente Lexicon Vivo (P1).
  Separar behaviour do módulo concreto permite substituição por mock (Mox) em testes.
  """

  @callback search(String.t(), float()) ::
              {:ok, list(map())} | {:error, term()}

  @callback get_concept(String.t(), boolean()) ::
              {:ok, map()} | {:error, term()}

  @callback get_fhir_code_system() ::
              {:ok, map()} | {:error, term()}
end

defmodule FhirFlBridge.Lexicon.Client do
  @moduledoc """
  # Parábola do Mensageiro e do Oráculo

  Em tempos antigos, havia um oráculo que conhecia todos os nomes das
  plantas medicinais em todas as línguas. Mas o oráculo não saía de seu
  templo. Para consultá-lo, era preciso um mensageiro — alguém que
  soubesse fazer as perguntas certas, interpretar as respostas e voltar
  a tempo com a informação.

  Este módulo é o mensageiro. O oráculo é o Lexicon Vivo (P1).

  — Parábola do Oráculo (inspirada na tradição dos mensageiros Iorubá)

  ---

  ## IMPORTANTE: cliente dinâmico (não usa `use Tesla` com `plug` estático)

  O `plug` macro do Tesla captura valores em *tempo de compilação*.
  Como `LEXICON_BASE_URL` varia por ambiente (localhost em dev local,
  `http://p1:8000` no Docker), o cliente é construído em *tempo de execução*
  via `build_client/0`, lendo o config no momento da chamada.
  """

  @behaviour FhirFlBridge.Lexicon.ClientBehaviour

  # ---------------------------------------------------------------
  # Construção dinâmica do cliente Tesla (runtime, não compile-time)
  # ---------------------------------------------------------------

  defp build_client do
    cfg = Application.get_env(:fhir_fl_bridge, :lexicon_client, [])
    base_url = Keyword.get(cfg, :base_url, "http://localhost:8000")
    api_key  = Keyword.get(cfg, :api_key, "")
    timeout  = Keyword.get(cfg, :timeout, 10_000)
    retries  = Keyword.get(cfg, :retry_attempts, 3)
    delay    = Keyword.get(cfg, :retry_delay, 500)

    middleware = [
      {Tesla.Middleware.BaseUrl, base_url},
      {Tesla.Middleware.Headers, [{"authorization", "Bearer #{api_key}"}]},
      {Tesla.Middleware.JSON, engine: Jason},
      {Tesla.Middleware.Timeout, timeout: timeout},
      Tesla.Middleware.Logger,
      {Tesla.Middleware.Retry,
       delay: delay,
       max_retries: retries,
       max_delay: 4_000,
       should_retry: fn
         {:ok, %{status: s}} when s in [429, 500, 502, 503, 504] -> true
         {:ok, _} -> false
         {:error, _} -> true
       end}
    ]

    Tesla.client(middleware, Tesla.Adapter.Hackney)
  end

  # ---------------------------------------------------------------
  # API pública
  # ---------------------------------------------------------------

  @impl FhirFlBridge.Lexicon.ClientBehaviour
  def search(query, min_confidence \\ 0.5) do
    case Tesla.get(build_client(), "/v1/search/",
           query: [q: query, min_confidence: min_confidence]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_search_results(body)}
      {:ok, %{status: 404}}             -> {:ok, []}
      {:ok, %{status: s, body: b}}      -> {:error, {:unexpected_status, s, b}}
      {:error, reason}                  -> {:error, {:http_error, reason}}
    end
  end

  @impl FhirFlBridge.Lexicon.ClientBehaviour
  def get_concept(concept_id, include_relations \\ true) do
    params = if include_relations, do: [query: [include_relations: true]], else: []

    case Tesla.get(build_client(), "/v1/concepts/#{concept_id}", params) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_concept(body)}
      {:ok, %{status: 404}}             -> {:error, :not_found}
      {:ok, %{status: s, body: b}}      -> {:error, {:unexpected_status, s, b}}
      {:error, reason}                  -> {:error, {:http_error, reason}}
    end
  end

  @impl FhirFlBridge.Lexicon.ClientBehaviour
  def get_fhir_code_system do
    case Tesla.get(build_client(), "/v1/fhir/CodeSystem") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s, body: b}}      -> {:error, {:unexpected_status, s, b}}
      {:error, reason}                  -> {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------
  # Variantes que aceitam cliente injetado (usadas em testes com Bypass)
  # ---------------------------------------------------------------

  @doc """
  Versão de `search/2` que aceita um `Tesla.Client` externo.
  Usada em testes para injetar um cliente apontando para o servidor Bypass.
  """
  def search_with_client(client, query, min_confidence \\ 0.5) do
    case Tesla.get(client, "/v1/search/",
           query: [q: query, min_confidence: min_confidence]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_search_results(body)}
      {:ok, %{status: 404}}             -> {:ok, []}
      {:ok, %{status: s, body: b}}      -> {:error, {:unexpected_status, s, b}}
      {:error, reason}                  -> {:error, {:http_error, reason}}
    end
  end

  @doc """
  Versão de `get_concept/2` que aceita um `Tesla.Client` externo.
  Usada em testes para injetar um cliente apontando para o servidor Bypass.
  """
  def get_concept_with_client(client, concept_id, include_relations \\ true) do
    params = if include_relations, do: [query: [include_relations: true]], else: []

    case Tesla.get(client, "/v1/concepts/#{concept_id}", params) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_concept(body)}
      {:ok, %{status: 404}}             -> {:error, :not_found}
      {:ok, %{status: s, body: b}}      -> {:error, {:unexpected_status, s, b}}
      {:error, reason}                  -> {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------
  # Parsers internos
  # ---------------------------------------------------------------

  defp parse_search_results(results) when is_list(results),
    do: Enum.map(results, &parse_single_result/1)
  defp parse_search_results(%{"results" => results}) when is_list(results),
    do: Enum.map(results, &parse_single_result/1)
  defp parse_search_results(_), do: []

  defp parse_single_result(r) do
    %{
      concept_id:       Map.get(r, "concept_id", ""),
      label:            Map.get(r, "prefLabel") || Map.get(r, "label", ""),
      lucene_score:     Map.get(r, "luceneScore", 0.0),
      confidence_score: Map.get(r, "confidenceScore", 0.0),
      tradition:        Map.get(r, "tradition", "unknown"),
      fhir_code:        Map.get(r, "fhir_code")
    }
  end

  defp parse_concept(body) do
    %{
      id:               Map.get(body, "id", ""),
      label:            Map.get(body, "label", ""),
      confidence_score: Map.get(body, "confidenceScore", 0.0),
      tradition:        Map.get(body, "tradition", "unknown"),
      relations:        Map.get(body, "relations", []),
      fhir_code:        Map.get(body, "fhir_code"),
      skos_broader:     Map.get(body, "broader", []),
      skos_narrower:    Map.get(body, "narrower", [])
    }
  end
end

defmodule FhirFlBridge.Lexicon do
  @moduledoc """
  Ponto de entrada unificado para operações do Lexicon Vivo.
  Resolve o módulo correto: Client real em prod/dev, Mock em testes.
  """

  def client_module do
    Application.get_env(
      :fhir_fl_bridge,
      :lexicon_client_module,
      FhirFlBridge.Lexicon.Client
    )
  end

  def search(query, min_confidence \\ 0.5),
    do: client_module().search(query, min_confidence)

  def get_concept(id, include_relations \\ true),
    do: client_module().get_concept(id, include_relations)

  def get_fhir_code_system,
    do: client_module().get_fhir_code_system()
end
