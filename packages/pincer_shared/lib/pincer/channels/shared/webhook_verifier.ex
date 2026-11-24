defmodule Pincer.Channels.Shared.WebhookVerifier do
  @moduledoc """
  Platform-specific webhook signature verification for supported channels.

  Each function computes the expected signature from the webhook payload
  and compares it against the provided signature.
  """

  @type verify_result :: :ok | {:error, :invalid_signature}

  @doc """
  Verifies a Feishu webhook signature.

  Computes `SHA256(timestamp <> nonce <> body)` as a lowercase hex string
  and compares it against the provided `signature`.

  Returns `:ok` if the signature is valid, `{:error, :invalid_signature}` otherwise.
  """
  @spec verify_feishu(String.t(), String.t(), String.t(), String.t()) :: verify_result()
  def verify_feishu(timestamp, nonce, body, signature) do
    verify_feishu(timestamp, nonce, body, signature, "")
  end

  @doc """
  Verifies a Feishu webhook signature with the app's encrypt key.

  Feishu signs `timestamp <> nonce <> encrypt_key <> body`.
  """
  @spec verify_feishu(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          verify_result()
  def verify_feishu(timestamp, nonce, body, signature, encrypt_key) do
    expected =
      :crypto.hash(:sha256, timestamp <> nonce <> encrypt_key <> body)
      |> Base.encode16(case: :lower)

    if secure_compare(expected, signature),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  @doc """
  Verifies a LINE webhook signature.

  Computes `HMAC-SHA256(body, channel_secret)` as a base64-encoded string
  and compares it against the provided `signature`.

  Returns `:ok` if the signature is valid, `{:error, :invalid_signature}` otherwise.
  """
  @spec verify_line(String.t(), String.t(), String.t()) :: verify_result()
  def verify_line(body, channel_secret, signature) do
    expected =
      :crypto.mac(:hmac, :sha256, channel_secret, body)
      |> Base.encode64()

    if secure_compare(expected, signature),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  @doc """
  Verifies a DingTalk webhook signature.

  Computes `HMAC-SHA256(timestamp <> "\\n" <> secret, secret)` as a base64-encoded
  string and compares it against the provided `signature`.

  Returns `:ok` if the signature is valid, `{:error, :invalid_signature}` otherwise.
  """
  @spec verify_dingtalk(String.t(), String.t(), String.t()) :: verify_result()
  def verify_dingtalk(timestamp, secret, signature) do
    string_to_sign = timestamp <> "\n" <> secret

    expected =
      :crypto.mac(:hmac, :sha256, secret, string_to_sign)
      |> Base.encode64()

    if secure_compare(expected, signature),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
