use futures::{Stream, StreamExt, TryStream, future::ready};

use crate::{Error, Result, utils::stream::TryExpect};

pub trait TryIgnore<Item>
where
	Item: Send,
	Self: Send + Sized,
{
	fn ignore_err(self) -> impl Stream<Item = Item> + Send;

	fn ignore_ok(self) -> impl Stream<Item = Error> + Send;
}

impl<Item, S> TryIgnore<Item> for S
where
	S: Stream<Item = Result<Item>> + Send + TryStream + TryExpect<Item>,
	Item: Send,
	Self: Send + Sized,
{
	#[cfg(debug_assertions)]
	#[inline]
	fn ignore_err(self: S) -> impl Stream<Item = Item> + Send { self.expect_ok() }

	#[cfg(not(debug_assertions))]
	#[inline]
	fn ignore_err(self: S) -> impl Stream<Item = Item> + Send {
		self.filter_map(|res| ready(res.ok()))
	}

	#[inline]
	fn ignore_ok(self: S) -> impl Stream<Item = Error> + Send {
		self.filter_map(|res| ready(res.err()))
	}
}
