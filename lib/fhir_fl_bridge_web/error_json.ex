defmodule FhirFlBridgeWeb.ErrorJSON do
  @moduledoc """
  Renderizador de erros JSON para Phoenix 1.7+.
  """

  def render("404.json", _assigns) do
    %{error: "not_found"}
  end

  def render("422.json", _assigns) do
    %{error: "unprocessable_entity"}
  end

  def render("500.json", _assigns) do
    %{error: "internal_server_error"}
  end

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
