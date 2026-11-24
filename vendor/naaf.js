/* Keyboard help for the admin UI. htmx still does the clicks.
   Ignored while a field is focused, so search and forms keep the keys. */
(function () {
  var go = {
    d: "/",
    c: "/clients",
    s: "/sites",
    n: "/dns-records",
    e: "/exit",
    t: "/troubleshoot",
    ",": "/settings"
  }
  var armed = false

  function typing (el) {
    if (!el || !el.tagName) return false
    var tag = el.tagName
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable
  }

  document.addEventListener("keydown", function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return
    if (typing(ev.target)) {
      if (ev.key === "Escape") ev.target.blur()
      return
    }
    if (ev.key === "?") {
      var dialog = document.getElementById("shortcuts")
      if (dialog && dialog.showModal) {
        if (dialog.open) dialog.close()
        else dialog.showModal()
      }
      return
    }
    if (ev.key === "/") {
      var query = document.getElementById("q")
      if (query) {
        ev.preventDefault()
        query.focus()
      }
      return
    }
    if (ev.key === "g") {
      armed = true
      return
    }
    if (armed && go[ev.key]) {
      ev.preventDefault()
      window.location.assign(go[ev.key])
    }
    armed = false
  })
})()
