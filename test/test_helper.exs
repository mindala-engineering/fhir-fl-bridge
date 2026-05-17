ExUnit.start()

# Configura sandbox do Ecto para testes isolados
Ecto.Adapters.SQL.Sandbox.mode(FhirFlBridge.Repo, :manual)

# Define o mock Mox para o cliente Lexicon (P1)
# O behaviour é definido em FhirFlBridge.Lexicon.ClientBehaviour
Mox.defmock(FhirFlBridge.Lexicon.ClientMock,
  for: FhirFlBridge.Lexicon.ClientBehaviour
)
