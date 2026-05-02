use std::panic::AssertUnwindSafe;

use futures_util::FutureExt;
use wasm_bindgen::prelude::*;

mod dispatcher;
mod envelope;

use envelope::{Envelope, ErrEnvelope, ErrKind};

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
/// `"message"`, `"reaction"`, or `"receipt"` and `payload_json` is the
/// JSON-serialized event. Events flow only after an `events.subscribe` call.
#[wasm_bindgen]
pub fn set_event_sink(sink: js_sys::Function) {
    dispatcher::set_event_sink(sink);
}

#[wasm_bindgen]
pub async fn call(method: String, args_json: String) -> String {
    let result = AssertUnwindSafe(dispatcher::dispatch(&method, &args_json))
        .catch_unwind()
        .await;

    let envelope: Envelope<serde_json::Value> = match result {
        Ok(Ok(value)) => Envelope::Ok { ok: value },
        Ok(Err(err)) => Envelope::Err { err },
        Err(panic_payload) => {
            let message = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            Envelope::Err {
                err: ErrEnvelope {
                    kind: ErrKind::PanicError,
                    message,
                    details: serde_json::json!({}),
                },
            }
        }
    };

    serde_json::to_string(&envelope).unwrap_or_else(|e| {
        format!(
            r#"{{"err":{{"kind":"SerdeError","message":"{}","details":{{}}}}}}"#,
            e
        )
    })
}
