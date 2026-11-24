defmodule Pincer.Utils.BoundedBody do
  @moduledoc """
  Req `into:` callback that stops reading a response once it exceeds a byte cap.

  Req buffers the whole body when `into:` is unset. Using this callback keeps
  memory bounded to the cap plus one chunk for callers that only need to reject
  oversized downloads.
  """

  @doc """
  Returns a Req streaming callback that accumulates chunks up to `max_bytes` and
  halts as soon as the cap is exceeded.
  """
  @spec callback(non_neg_integer()) ::
          ({:data, binary()}, {Req.Request.t(), Req.Response.t()} ->
             {:cont | :halt, {Req.Request.t(), Req.Response.t()}})
  def callback(max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    fn {:data, chunk}, {request, response} ->
      body = (response.body || "") <> chunk
      response = %{response | body: body}

      if byte_size(body) > max_bytes do
        {:halt, {request, response}}
      else
        {:cont, {request, response}}
      end
    end
  end
end
