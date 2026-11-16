# Mint's connections are opaque types, and mint_web_socket matches their structs inside
# `Mint.WebSocket.new/4`; OTP 28's Dialyzer then reads `new/4` as never succeeding, and the
# tunnel's match of its success as one that cannot happen. The client's tests open tunnels
# through that match (EhosTunnel.ClientTest).
[{"lib/ehos_tunnel/tunnel.ex", :pattern_match}]
