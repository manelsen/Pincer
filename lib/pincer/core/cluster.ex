defmodule Pincer.Core.Cluster do
  @moduledoc """
  Cluster topology configuration for libcluster.

  Reads topology from `config.yaml` under the `cluster:` key and falls back to
  an empty (single-node) topology when not configured.

  ## config.yaml example

      cluster:
        strategy: gossip        # gossip | kubernetes | epmd | dns
        gossip_port: 45892      # only for strategy: gossip

  ## Strategies

  | strategy     | when to use                                          |
  |---|---|
  | `gossip`     | LAN / docker-compose multi-container setups          |
  | `kubernetes` | k8s pod discovery via headless service               |
  | `epmd`       | explicit list of nodes (dev / static infra)          |
  | `dns`        | DNS-based discovery (ECS, Fly.io, Nomad)             |

  When the `cluster:` key is absent or `strategy` is `"none"`, the supervisor
  starts with an empty topology — safe for single-node deployments.
  """

  alias Pincer.Infra.Config

  @doc """
  Returns libcluster topology config based on `config.yaml`.
  """
  @spec topologies() :: keyword()
  def topologies do
    case Config.get(:cluster) do
      nil -> []
      cfg when is_map(cfg) -> build_topologies(cfg)
      _ -> []
    end
  end

  defp build_topologies(%{"strategy" => strategy} = cfg) when strategy in ["none", nil, ""] do
    _ = cfg
    []
  end

  defp build_topologies(%{"strategy" => "gossip"} = cfg) do
    port = Map.get(cfg, "gossip_port", 45892)

    [
      pincer: [
        strategy: Cluster.Strategy.Gossip,
        config: [port: port, multicast_addr: "230.1.1.251"]
      ]
    ]
  end

  defp build_topologies(%{"strategy" => "kubernetes"} = cfg) do
    service = Map.get(cfg, "kubernetes_service_name", "pincer")
    namespace = Map.get(cfg, "kubernetes_namespace", "default")
    basename = Map.get(cfg, "kubernetes_node_basename", "pincer")

    [
      pincer: [
        strategy: Cluster.Strategy.Kubernetes,
        config: [
          mode: :dns,
          kubernetes_node_basename: basename,
          kubernetes_selector: "app=#{service}",
          kubernetes_namespace: namespace
        ]
      ]
    ]
  end

  defp build_topologies(%{"strategy" => "epmd"} = cfg) do
    hosts = Map.get(cfg, "hosts", [])

    [
      pincer: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: Enum.map(hosts, &String.to_atom/1)]
      ]
    ]
  end

  defp build_topologies(%{"strategy" => "dns"} = cfg) do
    query = Map.get(cfg, "dns_query", "pincer.local")
    basename = Map.get(cfg, "dns_node_basename", "pincer")

    [
      pincer: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [query: query, node_basename: basename]
      ]
    ]
  end

  defp build_topologies(_cfg), do: []
end
