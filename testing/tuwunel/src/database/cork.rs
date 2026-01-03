use std::sync::Arc;

use crate::{Database, Engine};

pub struct Cork {
	engine: Arc<Engine>,
	flush: bool,
	sync: bool,
}

impl Database {
	#[inline]
	#[must_use]
	pub fn cork(&self) -> Cork { Cork::new(&self.engine, false, false) }

	#[inline]
	#[must_use]
	pub fn cork_and_flush(&self) -> Cork { Cork::new(&self.engine, true, false) }

	#[inline]
	#[must_use]
	pub fn cork_and_sync(&self) -> Cork { Cork::new(&self.engine, true, true) }
}

impl Cork {
	#[inline]
	pub(super) fn new(engine: &Arc<Engine>, flush: bool, sync: bool) -> Self {
		engine.cork();
		Self { engine: engine.clone(), flush, sync }
	}
}

impl Drop for Cork {
	fn drop(&mut self) {
		self.engine.uncork();
		if self.flush {
			self.engine.flush().ok();
		}
		if self.sync {
			self.engine.sync().ok();
		}
	}
}
