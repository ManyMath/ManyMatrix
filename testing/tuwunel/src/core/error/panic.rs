use std::{
	any::Any,
	panic::{RefUnwindSafe, UnwindSafe, panic_any},
};

use super::Error;
use crate::debug;

impl UnwindSafe for Error {}
impl RefUnwindSafe for Error {}

impl Error {
	#[inline]
	pub fn panic(self) -> ! { panic_any(self.into_panic()) }

	#[must_use]
	#[inline]
	pub fn from_panic(e: Box<dyn Any + Send + 'static>) -> Self {
		Self::Panic(debug::panic_str(&e), e.into())
	}

	#[inline]
	pub fn into_panic(self) -> Box<dyn Any + Send> {
		match self {
			| Self::JoinError(e) => e.into_panic(),
			| Self::Panic(_, e) | Self::PanicAny(e) =>
				e.into_inner().expect("Error contained panic"),
			| _ => Box::new(self),
		}
	}

	/// Get the panic message string.
	#[inline]
	pub fn panic_str(self) -> Option<&'static str> {
		self.is_panic().then(|| {
			let panic = self.into_panic();
			debug::panic_str(&panic)
		})
	}

	/// Check if the Error is trafficking a panic object.
	#[inline]
	pub fn is_panic(&self) -> bool {
		match &self {
			| Self::JoinError(e) => e.is_panic(),
			| Self::Panic(..) | Self::PanicAny(..) => true,
			| _ => false,
		}
	}
}
