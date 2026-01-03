use std::{convert::AsRef, fmt::Debug, sync::Arc};

use futures::{FutureExt, Stream, StreamExt, TryFutureExt, TryStreamExt, future::Either};
use rocksdb::Direction;
use serde::{Deserialize, Serialize};
use tokio::task;
use tuwunel_core::{Result, implement};

use super::rev_stream_from::is_cached;
use crate::{
	keyval::{Key, result_deserialize_key, serialize_key},
	stream,
};

#[implement(super::Map)]
pub fn rev_keys_from<'a, K, P>(
	self: &'a Arc<Self>,
	from: &P,
) -> impl Stream<Item = Result<Key<'_, K>>> + Send + use<'a, K, P>
where
	P: Serialize + ?Sized + Debug,
	K: Deserialize<'a> + Send,
{
	self.rev_keys_from_raw(from)
		.map(result_deserialize_key::<K>)
}

#[implement(super::Map)]
#[tracing::instrument(skip(self), level = "trace")]
pub fn rev_keys_from_raw<P>(
	self: &Arc<Self>,
	from: &P,
) -> impl Stream<Item = Result<Key<'_>>> + Send + use<'_, P>
where
	P: Serialize + ?Sized + Debug,
{
	let key = serialize_key(from).expect("failed to serialize query key");
	self.rev_raw_keys_from(&key)
}

#[implement(super::Map)]
pub fn rev_keys_raw_from<'a, K, P>(
	self: &'a Arc<Self>,
	from: &P,
) -> impl Stream<Item = Result<Key<'_, K>>> + Send + use<'a, K, P>
where
	P: AsRef<[u8]> + ?Sized + Debug + Sync,
	K: Deserialize<'a> + Send,
{
	self.rev_raw_keys_from(from)
		.map(result_deserialize_key::<K>)
}

#[implement(super::Map)]
#[tracing::instrument(skip(self, from), fields(%self), level = "trace")]
pub fn rev_raw_keys_from<P>(
	self: &Arc<Self>,
	from: &P,
) -> impl Stream<Item = Result<Key<'_>>> + Send + use<'_, P>
where
	P: AsRef<[u8]> + ?Sized + Debug,
{
	use crate::pool::Seek;

	let opts = super::iter_options_default(&self.engine);
	let state = stream::State::new(self, opts);
	if is_cached(self, from) {
		let state = state.init_rev(from.as_ref().into());
		return Either::Left(
			task::consume_budget()
				.map(move |()| stream::KeysRev::<'_>::from(state))
				.into_stream()
				.flatten(),
		);
	}

	let seek = Seek {
		map: self.clone(),
		dir: Direction::Reverse,
		key: Some(from.as_ref().into()),
		state: crate::pool::into_send_seek(state),
		res: None,
	};

	Either::Right(
		self.engine
			.pool
			.execute_iter(seek)
			.ok_into::<stream::KeysRev<'_>>()
			.into_stream()
			.try_flatten(),
	)
}
