use std::{
	collections::BTreeMap,
	fs::remove_dir_all,
	path::Path,
	sync::{Arc, Mutex},
};

use rocksdb::{Cache, Env, LruCacheOptions};
use tuwunel_core::{
	Result, Server, debug,
	utils::{math::usize_from_f64, result::LogErr},
};

use crate::{or_else, pool::Pool};

/// Some components are constructed prior to opening the database and must
/// outlive the database. These can also be shared between database instances
/// though at the time of this comment we only open one database per process.
/// These assets are housed in the shared Context.
pub(crate) struct Context {
	pub(crate) pool: Arc<Pool>,
	pub(crate) col_cache: Mutex<BTreeMap<String, Cache>>,
	pub(crate) row_cache: Mutex<Cache>,
	pub(crate) env: Mutex<Env>,
	pub(crate) server: Arc<Server>,
}

impl Context {
	pub(crate) fn new(server: &Arc<Server>) -> Result<Arc<Self>> {
		let config = &server.config;
		let cache_capacity_bytes = config.db_cache_capacity_mb * 1024.0 * 1024.0;

		let col_shard_bits = 7;
		let col_cache_capacity_bytes = usize_from_f64(cache_capacity_bytes * 0.50)?;

		let row_shard_bits = 7;
		let row_cache_capacity_bytes = usize_from_f64(cache_capacity_bytes * 0.50)?;

		let mut row_cache_opts = LruCacheOptions::default();
		row_cache_opts.set_num_shard_bits(row_shard_bits);
		row_cache_opts.set_capacity(row_cache_capacity_bytes);
		let row_cache = Cache::new_lru_cache_opts(&row_cache_opts);

		let mut col_cache_opts = LruCacheOptions::default();
		col_cache_opts.set_num_shard_bits(col_shard_bits);
		col_cache_opts.set_capacity(col_cache_capacity_bytes);
		let col_cache = Cache::new_lru_cache_opts(&col_cache_opts);
		let col_cache: BTreeMap<_, _> = [("Shared".to_owned(), col_cache)].into();

		let mut env = Env::new().or_else(or_else)?;

		if config.rocksdb_compaction_prio_idle {
			env.lower_thread_pool_cpu_priority();
		}

		if config.rocksdb_compaction_ioprio_idle {
			env.lower_thread_pool_io_priority();
		}

		Ok(Arc::new(Self {
			pool: Pool::new(server)?,
			col_cache: col_cache.into(),
			row_cache: row_cache.into(),
			env: env.into(),
			server: server.clone(),
		}))
	}
}

impl Drop for Context {
	#[cold]
	fn drop(&mut self) {
		debug!("Closing frontend pool");
		self.pool.close();

		let mut env = self.env.lock().expect("locked");

		debug!("Shutting down background threads");
		env.set_high_priority_background_threads(0);
		env.set_low_priority_background_threads(0);
		env.set_bottom_priority_background_threads(0);
		env.set_background_threads(0);

		debug!("Joining background threads...");
		env.join_all_threads();

		after_close(self, &self.server.config.database_path)
			.expect("Failed to execute after_close handler");
	}
}

/// For unit and integration tests the 'fresh' directive deletes found db.
pub(super) fn before_open(ctx: &Arc<Context>, path: &Path) -> Result {
	if ctx.server.config.test.contains("fresh") {
		match delete_database_for_testing(ctx, path) {
			| Err(e) if !e.is_not_found() => return Err(e),
			| _ => (),
		}
	}

	Ok(())
}

/// For unit and integration tests the 'cleanup' directive deletes after close
/// to cleanup.
fn after_close(ctx: &Context, path: &Path) -> Result {
	if ctx.server.config.test.contains("cleanup") {
		delete_database_for_testing(ctx, path)
			.log_err()
			.ok();
	}

	Ok(())
}

/// For unit and integration tests; removes the database directory when called.
/// To prevent misuse, cfg!(test) must be true for a unit test or the
/// integration test server is named localhost.
#[tracing::instrument(level = "debug", skip_all)]
fn delete_database_for_testing(ctx: &Context, path: &Path) -> Result {
	let config = &ctx.server.config;
	let localhost = config
		.server_name
		.as_str()
		.starts_with("localhost");

	if !cfg!(test) && !localhost {
		return Ok(());
	}

	debug_assert!(
		config.test.contains("cleanup") | config.test.contains("fresh"),
		"missing any test directive legitimating this call.",
	);

	remove_dir_all(path).map_err(Into::into)
}
