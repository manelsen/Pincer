# Custom Postgrex type registry with pgvector support.
Postgrex.Types.define(Pincer.Infra.PostgrexTypes, Pgvector.extensions(), json: Jason)
