defmodule FhirFlBridge.FHIR.Validator do
  @moduledoc """
  # Parábola da Balança do Mercado

  No mercado antigo de Tombuctu, havia uma balança de três pratos.
  O prato da direita era dourado: aceitava tudo sem questão.
  O prato da esquerda era vermelho: rejeitava sem apelo.
  O prato do meio era prateado: reservado para o que precisava
  de mais olhos antes de decidir.

  O comerciante sábio não usava só a balança — usava o juízo.
  Mas sem a balança, o juízo não tinha onde se apoiar.

  Este módulo é a balança do P2. O ouro, a prata e o vermelho
  são os limiares que o Guardião Epistêmico definiu.

  — Parábola da Balança (tradição dos comerciantes do Mali)

  ---

  ## Regras de Threshold

  Implementa as três regras formais que governam o destino de um
  mapeamento terminológico entre código FHIR local e conceito Lexicon:

  | confidence_score  | status           | ação                              |
  |-------------------|------------------|-----------------------------------|
  | >= 0.85           | :auto_accepted   | aceito automaticamente            |
  | 0.50 <= x < 0.85  | :pending_review  | fila do Guardião Epistêmico       |
  | < 0.50            | :rejected        | bloqueado até revisão humana      |

  Esses limiares são configurados em `config.exs` e NÃO devem ser
  alterados sem aprovação formal do Guardião Epistêmico.
  """

  # Lê limiares da configuração (permite ajuste sem recompilar)
  @auto_accept_threshold Application.compile_env(
                           :fhir_fl_bridge,
                           [:epistemic_thresholds, :auto_accept],
                           0.85
                         )

  @review_floor_threshold Application.compile_env(
                             :fhir_fl_bridge,
                             [:epistemic_thresholds, :review_floor],
                             0.50
                           )

  @type confidence_score :: float()
  @type mapping_status :: :auto_accepted | :pending_review | :rejected

  @type validation_result :: %{
          status: mapping_status(),
          confidence_score: confidence_score(),
          threshold_applied: float(),
          requires_human_review: boolean()
        }

  @doc """
  Aplica as regras de threshold epistêmico a um score de confiança.

  ## Exemplos

      iex> FhirFlBridge.FHIR.Validator.apply_threshold(0.91)
      %{status: :auto_accepted, confidence_score: 0.91, requires_human_review: false, ...}

      iex> FhirFlBridge.FHIR.Validator.apply_threshold(0.70)
      %{status: :pending_review, confidence_score: 0.70, requires_human_review: true, ...}

      iex> FhirFlBridge.FHIR.Validator.apply_threshold(0.30)
      %{status: :rejected, confidence_score: 0.30, requires_human_review: true, ...}
  """
  @spec apply_threshold(confidence_score()) :: validation_result()
  def apply_threshold(confidence_score) when is_float(confidence_score) do
    status = classify(confidence_score)

    %{
      status: status,
      confidence_score: confidence_score,
      threshold_applied: threshold_for(status),
      requires_human_review: status in [:pending_review, :rejected],
      auto_accept_threshold: @auto_accept_threshold,
      review_floor_threshold: @review_floor_threshold
    }
  end

  @doc """
  Retorna os valores de threshold atualmente configurados.

  Útil para expor via API para o Guardião Epistêmico saber os limites vigentes.
  """
  @spec current_thresholds() :: %{auto_accept: float(), review_floor: float()}
  def current_thresholds do
    %{
      auto_accept: @auto_accept_threshold,
      review_floor: @review_floor_threshold
    }
  end

  @doc """
  Verifica se um score é aceitável para mapeamento automático.
  """
  @spec auto_acceptable?(confidence_score()) :: boolean()
  def auto_acceptable?(score), do: score >= @auto_accept_threshold

  @doc """
  Verifica se um score requer revisão humana (pending ou rejected).
  """
  @spec requires_review?(confidence_score()) :: boolean()
  def requires_review?(score), do: score < @auto_accept_threshold

  # -------------------------------------------------------------------
  # Implementação privada
  # -------------------------------------------------------------------

  defp classify(score) when score >= @auto_accept_threshold, do: :auto_accepted
  defp classify(score) when score >= @review_floor_threshold, do: :pending_review
  defp classify(_score), do: :rejected

  defp threshold_for(:auto_accepted), do: @auto_accept_threshold
  defp threshold_for(:pending_review), do: @review_floor_threshold
  defp threshold_for(:rejected), do: @review_floor_threshold
end
