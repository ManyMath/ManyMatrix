use wasm_bindgen::prelude::*;

mod dispatcher;
mod envelope;

use envelope::Envelope;

#[wasm_bindgen(start)]
pub fn init() {
    console_error_panic_hook::set_once();
    tracing_wasm::set_as_global_default();
    tracing::info!(
        "manymatrix-web init ok, crate_version={}",
        env!("CARGO_PKG_VERSION")
    );
}

/// Register a JS function to receive pushed events from the sync loop.
///
/// The sink is called with `(kind, payload_json)` where `kind` is one of
/// `"message"`, `"reaction"`, `"receipt"`, `"custom_event"`, `"sync_status"`,
/// or `"session_update"` and `payload_json` is the JSON-serialized event.
/// Timeline events flow only after an `events.subscribe` call, and custom
/// events only for types registered with `events.subscribe_custom`; sync
/// status changes are emitted by the running sync loop.
#[wasm_bindgen]
pub fn set_event_sink(sink: js_sys::Function) {
    dispatcher::set_event_sink(sink);
}

/// Run one dispatcher method and return its `{ok}` / `{err}` envelope as JSON.
///
/// `wasm32-unknown-unknown` only supports `panic = "abort"`, so a panic in a
/// dispatcher method cannot be caught here: the hook logs it and the module
/// traps with `RuntimeError: unreachable`, leaving this call's promise
/// unsettled. The hosting worker treats such a trap as fatal for the instance
/// and answers the outstanding requests with `PanicError` itself.
#[wasm_bindgen]
pub async fn call(method: String, args_json: String) -> String {
    let envelope: Envelope<serde_json::Value> =
        match dispatcher::dispatch(&method, &args_json).await {
            Ok(value) => Envelope::Ok { ok: value },
            Err(err) => Envelope::Err { err },
        };

    serde_json::to_string(&envelope).unwrap_or_else(|e| {
        serde_json::json!({
            "err": {"kind": "SerdeError", "message": e.to_string(), "details": {}},
        })
        .to_string()
    })
}
