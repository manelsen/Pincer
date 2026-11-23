defmodule Pincer.Infra.UUID do
  @moduledoc "Generates RFC 4122 version 4 UUID strings without Ecto."

  import Bitwise

  @spec generate() :: String.t()
  def generate do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Version 4 and RFC 4122 variant bits.
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    <<a::32, b::16, c::16, d::16, e::48>>
    |> Base.encode16(case: :lower)
    |> format()
  end

  defp format(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    Enum.join([a, b, c, d, e], "-")
  end
end
