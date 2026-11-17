defmodule EhosTunnel.KeyTest do
  use ExUnit.Case, async: true

  alias EhosTunnel.Key

  describe "public_key/1 and decode_public_key/1" do
    test "a key's publicKey reads back to its SubjectPublicKeyInfo" do
      key = Key.generate()

      assert Key.decode_public_key(Key.public_key(key)) == {:ok, Key.spki(key)}
    end

    test "the publicKey is base64 with padding of a P-256 SubjectPublicKeyInfo, as ASN.1 reads it" do
      key = Key.generate()
      {:ok, der} = Base.decode64(Key.public_key(key))
      {:ECPrivateKey, _version, _private, _curve, point, _attributes} = key
      curve = {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}

      assert :public_key.der_decode(:SubjectPublicKeyInfo, der) ==
               {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {1, 2, 840, 10_045, 2, 1}, curve},
                point}

      assert byte_size(point) == 65 and binary_part(point, 0, 1) == <<4>>
    end

    test "two keys differ" do
      assert Key.public_key(Key.generate()) != Key.public_key(Key.generate())
    end

    test "a key on another curve is refused" do
      for curve <- [:secp384r1, :secp256k1, :secp521r1] do
        assert Key.decode_public_key(encode_ec(curve)) == {:error, :not_p256}, inspect(curve)
      end
    end

    test "an RSA or Ed25519 key is refused" do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = rsa

      rsa_spki =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, modulus, exponent})

      {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

      ed25519_spki =
        :public_key.pem_entry_encode(
          :SubjectPublicKeyInfo,
          {{:ECPoint, public}, {:namedCurve, {1, 3, 101, 112}}}
        )

      assert Key.decode_public_key(Base.encode64(elem(rsa_spki, 1))) == {:error, :not_p256}
      assert Key.decode_public_key(Base.encode64(elem(ed25519_spki, 1))) == {:error, :not_p256}
    end

    test "a compressed point, a byte added or a byte taken is refused" do
      key = Key.generate()
      der = Key.spki(key)
      {:ECPrivateKey, _version, _private, _curve, <<4, x::binary-32, y::binary-32>>, _} = key
      <<_last_y::7, odd::1>> = binary_part(y, 31, 1)
      compressed = <<2 + odd, x::binary>>

      compressed_spki =
        <<0x30, 0x39, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06,
          0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x22, 0x00>> <> compressed

      assert Key.decode_public_key(Base.encode64(compressed_spki)) == {:error, :not_p256}
      assert Key.decode_public_key(Base.encode64(der <> <<0>>)) == {:error, :not_p256}
      assert Key.decode_public_key(Base.encode64(binary_part(der, 0, 90))) == {:error, :not_p256}
      assert Key.decode_public_key("") == {:error, :not_p256}
      # Refused unread: this holds the answer; the 1024-character bound is what keeps it cheap.
      assert Key.decode_public_key(String.duplicate("A", 2_000_000)) == {:error, :not_p256}
    end

    test "a point off the curve is refused" do
      <<prefix::binary-27, x::binary-32, y::unsigned-big-256>> = Key.spki(Key.generate())

      assert Key.decode_public_key(Base.encode64(<<prefix::binary, x::binary, y + 1::256>>)) ==
               {:error, :not_on_curve}
    end

    test "what is not base64 with padding is refused, of any type" do
      encoded = Key.public_key(Key.generate())

      for value <- [
            String.trim_trailing(encoded, "="),
            "-" <> binary_part(encoded, 1, 123),
            " " <> encoded,
            nil,
            42,
            String.to_charlist(encoded)
          ] do
        assert Key.decode_public_key(value) == {:error, :not_base64}, inspect(value)
      end
    end
  end

  test "a second base64 spelling of the same key is refused" do
    # 91 bytes end in one byte over a group of three: "XY==", where Y holds 2 bits of the key and
    # 4 bits that are not. Setting those 4 bits spells the same bytes in another way.
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    encoded = Key.public_key(Key.generate())
    <<head::binary-121, last, "==">> = encoded
    index = Enum.find_index(alphabet, &(&1 == last))
    spelling = head <> <<Enum.at(alphabet, Bitwise.bor(index, 0b1111))>> <> "=="

    assert spelling != encoded
    assert Base.decode64(spelling) == Base.decode64(encoded)
    assert Key.decode_public_key(spelling) == {:error, :not_base64}
  end

  describe "fingerprint/1" do
    test "is the SHA-256 of the SubjectPublicKeyInfo, raw and in base64" do
      spki = Key.spki(Key.generate())

      assert Key.fingerprint(spki) == :crypto.hash(:sha256, spki)
      assert Key.encoded_fingerprint(spki) == Base.encode64(:crypto.hash(:sha256, spki))
    end
  end

  defp encode_ec(curve) do
    {:ECPrivateKey, _version, _private, params, point, _attributes} =
      :public_key.generate_key({:namedCurve, curve})

    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, params})

    Base.encode64(der)
  end
end
