defmodule FhirFlBridge.FL.AggregatorTest do
  @moduledoc """
  Testes do algoritmo FedAvg ponderado por confiança epistêmica.

  Estes testes verificam a corretude matemática da agregação.
  São especialmente relevantes para a tese PPGINFOS — o algoritmo
  de ponderação por confidenceScore é a contribuição original do P2
  ao campo de Federated Learning em saúde.

  ## Como verificar os cálculos manualmente

  Para dois participantes com gradientes [a, b, c] e pesos w1, w2:

      θ_i = w_i / (w1 + w2)
      resultado[j] = θ_1 * a[j] + θ_2 * b[j]

  Exemplo com pesos 0.9 e 0.6, gradientes [1.0, 2.0] e [3.0, 4.0]:
      total_weight = 0.9 + 0.6 = 1.5
      θ_1 = 0.9 / 1.5 = 0.6
      θ_2 = 0.6 / 1.5 = 0.4
      resultado[0] = 0.6 * 1.0 + 0.4 * 3.0 = 0.6 + 1.2 = 1.8
      resultado[1] = 0.6 * 2.0 + 0.4 * 4.0 = 1.2 + 1.6 = 2.8
  """

  use ExUnit.Case, async: true

  alias FhirFlBridge.FL.Aggregator

  # Tolerância para comparação de floats
  @delta 0.0001

  # -------------------------------------------------------------------
  # weighted_fedavg/1 — casos de sucesso
  # -------------------------------------------------------------------

  describe "weighted_fedavg/1 — casos de sucesso" do
    test "agrega dois participantes com pesos diferentes" do
      participants = [
        %{
          municipality_code: "4205407",
          confidence_weight: 0.9,
          local_gradients: %{"layer_1" => [1.0, 2.0]},
          samples_count: 100,
          status: :submitted
        },
        %{
          municipality_code: "4202404",
          confidence_weight: 0.6,
          local_gradients: %{"layer_1" => [3.0, 4.0]},
          samples_count: 80,
          status: :submitted
        }
      ]

      assert {:ok, result} = Aggregator.weighted_fedavg(participants)

      [v0, v1] = result.global_weights["layer_1"]

      # θ_1 = 0.9/1.5 = 0.6, θ_2 = 0.6/1.5 = 0.4
      assert_in_delta v0, 1.8, @delta   # 0.6*1.0 + 0.4*3.0
      assert_in_delta v1, 2.8, @delta   # 0.6*2.0 + 0.4*4.0
    end

    test "participante com maior weight tem mais influência" do
      # P1 tem peso 0.9 (alta confiança), P2 tem peso 0.1 (baixa confiança)
      # O resultado deve ser mais próximo dos gradientes de P1
      participants = [
        %{
          municipality_code: "p1",
          confidence_weight: 0.9,
          local_gradients: %{"layer_1" => [10.0]},
          samples_count: 100,
          status: :submitted
        },
        %{
          municipality_code: "p2",
          confidence_weight: 0.1,
          local_gradients: %{"layer_1" => [0.0]},
          samples_count: 10,
          status: :submitted
        }
      ]

      {:ok, result} = Aggregator.weighted_fedavg(participants)

      [v0] = result.global_weights["layer_1"]

      # θ_1 = 0.9, θ_2 = 0.1 (já normalizado)
      # resultado = 0.9 * 10.0 + 0.1 * 0.0 = 9.0
      assert_in_delta v0, 9.0, @delta
      # Confirma que resultado está mais próximo de 10.0 (P1) do que de 0.0 (P2)
      assert v0 > 5.0
    end

    test "participantes com pesos iguais produzem média simples" do
      participants = [
        %{
          municipality_code: "p1",
          confidence_weight: 0.5,
          local_gradients: %{"layer_1" => [2.0, 4.0]},
          samples_count: 50,
          status: :submitted
        },
        %{
          municipality_code: "p2",
          confidence_weight: 0.5,
          local_gradients: %{"layer_1" => [4.0, 6.0]},
          samples_count: 50,
          status: :submitted
        }
      ]

      {:ok, result} = Aggregator.weighted_fedavg(participants)

      [v0, v1] = result.global_weights["layer_1"]

      # Com pesos iguais: média aritmética
      assert_in_delta v0, 3.0, @delta   # (2.0 + 4.0) / 2
      assert_in_delta v1, 5.0, @delta   # (4.0 + 6.0) / 2
    end

    test "agrega múltiplas camadas simultaneamente" do
      participants = [
        %{
          municipality_code: "p1",
          confidence_weight: 0.7,
          local_gradients: %{
            "layer_1" => [1.0, 2.0],
            "layer_2" => [0.5],
            "bias" => [0.1, 0.2, 0.3]
          },
          samples_count: 70,
          status: :submitted
        },
        %{
          municipality_code: "p2",
          confidence_weight: 0.3,
          local_gradients: %{
            "layer_1" => [3.0, 4.0],
            "layer_2" => [1.5],
            "bias" => [0.4, 0.5, 0.6]
          },
          samples_count: 30,
          status: :submitted
        }
      ]

      {:ok, result} = Aggregator.weighted_fedavg(participants)

      # Verifica que todas as camadas foram agregadas
      assert Map.has_key?(result.global_weights, "layer_1")
      assert Map.has_key?(result.global_weights, "layer_2")
      assert Map.has_key?(result.global_weights, "bias")

      # Verifica tamanhos
      assert length(result.global_weights["layer_1"]) == 2
      assert length(result.global_weights["layer_2"]) == 1
      assert length(result.global_weights["bias"]) == 3
    end

    test "metadados da agregação estão corretos" do
      participants = [
        %{
          municipality_code: "p1",
          confidence_weight: 0.8,
          local_gradients: %{"layer_1" => [1.0]},
          samples_count: 100,
          status: :submitted
        },
        %{
          municipality_code: "p2",
          confidence_weight: 0.6,
          local_gradients: %{"layer_1" => [2.0]},
          samples_count: 60,
          status: :submitted
        }
      ]

      {:ok, result} = Aggregator.weighted_fedavg(participants)

      assert result.effective_participants == 2
      assert_in_delta result.total_weight, 1.4, @delta
      assert result.aggregation_strategy == :weighted_fedavg
      assert length(result.per_participant_contribution) == 2
    end

    test "ignora participantes com status != :submitted" do
      participants = [
        %{
          municipality_code: "florianopolis",
          confidence_weight: 0.9,
          local_gradients: %{"layer_1" => [1.0]},
          samples_count: 100,
          status: :submitted
        },
        %{
          municipality_code: "blumenau",
          confidence_weight: 0.8,
          local_gradients: %{"layer_1" => [5.0]},
          samples_count: 80,
          status: :timeout   # Este é ignorado
        },
        %{
          municipality_code: "joinville",
          confidence_weight: 0.7,
          local_gradients: nil,
          samples_count: 0,
          status: :failed   # Este também é ignorado
        }
      ]

      {:ok, result} = Aggregator.weighted_fedavg(participants)

      # Apenas florianopolis foi incluído
      assert result.effective_participants == 1
      # Com apenas um participante, o resultado é seus próprios gradientes * 1.0
      [v0] = result.global_weights["layer_1"]
      assert_in_delta v0, 1.0, @delta
    end
  end

  # -------------------------------------------------------------------
  # weighted_fedavg/1 — casos de erro
  # -------------------------------------------------------------------

  describe "weighted_fedavg/1 — casos de erro" do
    test "retorna erro com lista vazia" do
      assert {:error, :insufficient_participants} = Aggregator.weighted_fedavg([])
    end

    test "retorna erro quando nenhum participante tem gradientes" do
      participants = [
        %{
          municipality_code: "p1",
          confidence_weight: 0.9,
          local_gradients: nil,
          samples_count: 0,
          status: :timeout
        }
      ]

      assert {:error, :insufficient_participants} = Aggregator.weighted_fedavg(participants)
    end
  end

  # -------------------------------------------------------------------
  # compute_weights/1
  # -------------------------------------------------------------------

  describe "compute_weights/1" do
    test "calcula pesos normalizados corretamente" do
      participants = [
        %{municipality_code: "p1", confidence_weight: 0.8, samples_count: 100, status: :submitted, local_gradients: %{}},
        %{municipality_code: "p2", confidence_weight: 0.2, samples_count: 50, status: :submitted, local_gradients: %{}}
      ]

      weights = Aggregator.compute_weights(participants)

      assert length(weights) == 2

      p1_weight = Enum.find(weights, &(&1.municipality_code == "p1"))
      p2_weight = Enum.find(weights, &(&1.municipality_code == "p2"))

      assert_in_delta p1_weight.normalized_weight, 0.8, @delta  # 0.8 / (0.8+0.2)
      assert_in_delta p2_weight.normalized_weight, 0.2, @delta  # 0.2 / (0.8+0.2)

      # A soma dos pesos normalizados deve ser 1.0
      total_normalized = Enum.sum(Enum.map(weights, & &1.normalized_weight))
      assert_in_delta total_normalized, 1.0, @delta
    end
  end
end
