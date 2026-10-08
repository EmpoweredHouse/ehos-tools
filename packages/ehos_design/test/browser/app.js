// The script of the browser test's page, as a host would write its own: LiveView, and the
// design system's hooks from `phoenix-colocated/ehos_design` (eh-os D-86).
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as designHooks} from "phoenix-colocated/ehos_design"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...designHooks},
})

liveSocket.connect()
window.liveSocket = liveSocket
