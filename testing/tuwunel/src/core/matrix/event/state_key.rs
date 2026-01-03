use std::cmp::Ordering;

use ruma::events::StateEventType;
use smallstr::SmallString;

pub type TypeStateKey = (StateEventType, StateKey);
pub type StateKey = SmallString<[u8; INLINE_SIZE]>;

const INLINE_SIZE: usize = 48;

#[inline]
#[must_use]
pub fn cmp(a: &TypeStateKey, b: &TypeStateKey) -> Ordering { a.0.cmp(&b.0).then(a.1.cmp(&b.1)) }

#[inline]
#[must_use]
pub fn rcmp(a: &TypeStateKey, b: &TypeStateKey) -> Ordering { b.0.cmp(&a.0).then(b.1.cmp(&a.1)) }
