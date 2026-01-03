mod execute;
mod format;

use std::sync::Arc;

use tuwunel_core::Result;

use crate::services::OnceServices;

pub struct Service {
	services: Arc<OnceServices>,
}

impl crate::Service for Service {
	fn build(args: &crate::Args<'_>) -> Result<Arc<Self>> {
		Ok(Arc::new(Self { services: args.services.clone() }))
	}

	fn name(&self) -> &str { crate::service::make_name(std::module_path!()) }
}
