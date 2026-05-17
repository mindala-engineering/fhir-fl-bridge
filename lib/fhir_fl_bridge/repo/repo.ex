defmodule FhirFlBridge.Repo do
  @moduledoc """
  # Parábola do Aquífero

  Sob as terras áridas do sertão, há aquíferos que nunca secam.
  O viajante não os vê — mas sabe que estão lá. Quando cava no
  lugar certo, a água surge. O aquífero não decide a quem serve:
  ele simplesmente está, disponível, fiel, silencioso.

  Este módulo é o aquífero do P2. Invisível nas operações diárias,
  mas presente em todo acesso a dados. Sem ele, o serviço seca.

  — Parábola do Aquífero (tradição dos sertanejos do Rio Grande do Norte)
  """

  use Ecto.Repo,
    otp_app: :fhir_fl_bridge,
    adapter: Ecto.Adapters.Postgres
end
