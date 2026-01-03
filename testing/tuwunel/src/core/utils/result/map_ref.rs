use super::Result;

pub trait MapRef<T, E> {
	fn map_ref<U, F>(self, op: F) -> Result<U, E>
	where
		F: FnOnce(&T) -> U;
}

impl<T, E> MapRef<T, E> for Result<T, E> {
	#[inline]
	fn map_ref<U, F>(self, op: F) -> Result<U, E>
	where
		F: FnOnce(&T) -> U,
	{
		self.map(|t| op(&t))
	}
}
