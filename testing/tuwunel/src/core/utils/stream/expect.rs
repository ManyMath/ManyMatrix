use futures::{Stream, StreamExt, TryStream};

use crate::Result;

pub trait TryExpect<Item>
where
	Item: Send,
	Self: Send + Sized,
{
	fn expect_ok(self) -> impl Stream<Item = Item> + Send;

	fn map_expect(self, msg: &str) -> impl Stream<Item = Item> + Send;
}

impl<Item, S> TryExpect<Item> for S
where
	S: Stream<Item = Result<Item>> + Send + TryStream,
	Item: Send,
	Self: Send + Sized,
{
	#[inline]
	fn expect_ok(self: S) -> impl Stream<Item = Item> + Send {
		self.map_expect("stream expectation failure")
	}

	//TODO: move to impl MapExpect
	#[inline]
	fn map_expect(self, msg: &str) -> impl Stream<Item = Item> + Send {
		self.map(|res| res.expect(msg))
	}
}
