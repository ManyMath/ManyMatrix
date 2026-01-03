use super::Result;

pub trait AndThenRef<T, E> {
	fn and_then_ref<U, F>(self, op: F) -> Result<U, E>
	where
		F: FnOnce(&T) -> Result<U, E>;
}

impl<T, E> AndThenRef<T, E> for Result<T, E> {
	#[inline]
	fn and_then_ref<U, F>(self, op: F) -> Result<U, E>
	where
		F: FnOnce(&T) -> Result<U, E>,
	{
		self.and_then(|t| op(&t))
	}
}
