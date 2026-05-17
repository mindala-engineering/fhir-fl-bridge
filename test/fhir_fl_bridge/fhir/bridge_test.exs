defmodule FhirFlBridge.FHIR.ValidatorTest do
  @moduledoc """
  Testes das regras de threshold epistêmico.

  Estes testes são os mais críticos do sistema: garantem que as regras
  de aceitação/revisão/rejeição de mapeamentos estão corretas.
  Um bug aqui significa mapeamentos errados chegando ao SUS.
  """

  use ExUnit.Case, async: true

  alias FhirFlBridge.FHIR.Validator

  # -------------------------------------------------------------------
  # apply_threshold/1
  # -------------------------------------------------------------------

  describe "apply_threshold/1 — auto_accepted (score >= 0.85)" do
    test "score exatamente no limiar de auto_accept" do
      result = Validator.apply_threshold(0.85)

      assert result.status == :auto_accepted
      assert result.requires_human_review == false
    end

    test "score acima do limiar" do
      result = Validator.apply_threshold(0.99)

      assert result.status == :auto_accepted
      assert result.confidence_score == 0.99
    end

    test "score 1.0 (perfeito) é auto_accepted" do
      result = Validator.apply_threshold(1.0)
      assert result.status == :auto_accepted
    end
  end

  describe "apply_threshold/1 — pending_review (0.50 <= score < 0.85)" do
    test "score logo abaixo do limiar de auto_accept" do
      result = Validator.apply_threshold(0.84)

      assert result.status == :pending_review
      assert result.requires_human_review == true
    end

    test "score exatamente no limiar review_floor" do
      result = Validator.apply_threshold(0.50)

      assert result.status == :pending_review
    end

    test "score no meio da zona de revisão" do
      result = Validator.apply_threshold(0.70)

      assert result.status == :pending_review
      assert result.confidence_score == 0.70
    end
  end

  describe "apply_threshold/1 — rejected (score < 0.50)" do
    test "score logo abaixo do review_floor" do
      result = Validator.apply_threshold(0.49)

      assert result.status == :rejected
      assert result.requires_human_review == true
    end

    test "score zero é rejeitado" do
      result = Validator.apply_threshold(0.0)

      assert result.status == :rejected
    end

    test "score muito baixo" do
      result = Validator.apply_threshold(0.10)

      assert result.status == :rejected
    end
  end

  # -------------------------------------------------------------------
  # Funções auxiliares
  # -------------------------------------------------------------------

  describe "auto_acceptable?/1" do
    test "retorna true para score >= 0.85" do
      assert Validator.auto_acceptable?(0.85) == true
      assert Validator.auto_acceptable?(0.91) == true
      assert Validator.auto_acceptable?(1.0) == true
    end

    test "retorna false para score < 0.85" do
      assert Validator.auto_acceptable?(0.84) == false
      assert Validator.auto_acceptable?(0.50) == false
      assert Validator.auto_acceptable?(0.0) == false
    end
  end

  describe "requires_review?/1" do
    test "retorna true para score abaixo de auto_accept" do
      assert Validator.requires_review?(0.70) == true
      assert Validator.requires_review?(0.30) == true
    end

    test "retorna false para score >= 0.85" do
      assert Validator.requires_review?(0.85) == false
      assert Validator.requires_review?(0.99) == false
    end
  end

  describe "current_thresholds/0" do
    test "retorna os limiares configurados" do
      thresholds = Validator.current_thresholds()

      assert Map.has_key?(thresholds, :auto_accept)
      assert Map.has_key?(thresholds, :review_floor)
      assert thresholds.auto_accept > thresholds.review_floor
    end
  end

  # -------------------------------------------------------------------
  # Propriedades invariantes
  # -------------------------------------------------------------------

  describe "invariantes de threshold" do
    test "todo score em [0.0, 1.0] recebe exatamente um status" do
      test_scores = [0.0, 0.10, 0.49, 0.50, 0.70, 0.84, 0.85, 0.91, 1.0]

      for score <- test_scores do
        result = Validator.apply_threshold(score)
        assert result.status in [:auto_accepted, :pending_review, :rejected],
               "Score #{score} produziu status inválido: #{result.status}"
      end
    end

    test "auto_accepted nunca requer revisão humana" do
      result = Validator.apply_threshold(0.91)
      assert result.status == :auto_accepted
      assert result.requires_human_review == false
    end

    test "rejected sempre requer revisão humana" do
      result = Validator.apply_threshold(0.30)
      assert result.status == :rejected
      assert result.requires_human_review == true
    end
  end
end
