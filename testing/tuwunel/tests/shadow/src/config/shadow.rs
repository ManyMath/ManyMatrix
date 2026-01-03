use std::{collections::BTreeMap, path::Path};

use serde::Serialize;

/// Top-level Shadow simulation config.
/// Serializes to Shadow's YAML format via serde_yaml.
#[derive(Serialize, Clone, Debug)]
pub struct ShadowConfig {
	pub general: General,
	pub network: Network,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub host_option_defaults: Option<HostOptionDefaults>,
	pub hosts: BTreeMap<String, Host>,
}

#[derive(Serialize, Clone, Debug)]
pub struct General {
	pub stop_time: String,
	pub seed: u32,
	pub model_unblocked_syscall_latency: bool,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub data_directory: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub log_level: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct Network {
	pub graph: NetworkGraph,
}

#[derive(Serialize, Clone, Debug)]
pub struct NetworkGraph {
	#[serde(rename = "type")]
	pub graph_type: String,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub inline: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct HostOptionDefaults {
	#[serde(skip_serializing_if = "Option::is_none")]
	pub pcap_enabled: Option<bool>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub pcap_capture_size: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct Host {
	pub network_node_id: u32,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub host_options: Option<HostOptions>,
	pub processes: Vec<Process>,
}

#[derive(Serialize, Clone, Debug)]
pub struct HostOptions {
	#[serde(skip_serializing_if = "Option::is_none")]
	pub pcap_enabled: Option<bool>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub pcap_capture_size: Option<String>,
}

/// Shadow's expected_final_state; untagged to match Shadow's format.
#[derive(Serialize, Clone, Debug)]
#[serde(untagged)]
pub enum ProcessFinalState {
	Running(RunningVal),
	Exited { exited: i32 },
}

#[derive(Serialize, Clone, Debug)]
pub enum RunningVal {
	#[serde(rename = "running")]
	Running,
}

#[derive(Serialize, Clone, Debug)]
pub struct Process {
	pub path: String,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub args: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub start_time: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub expected_final_state: Option<ProcessFinalState>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub environment: Option<BTreeMap<String, String>>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub shutdown_time: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub shutdown_signal: Option<String>,
}

impl ShadowConfig {
	/// Serialize to Shadow YAML format.
	pub fn to_yaml(&self) -> Result<String, serde_yaml::Error> {
		serde_yaml::to_string(self)
	}
}

/// Deterministic defaults: explicit seed, stop_time, and
/// model_unblocked_syscall_latency (required by Shadow).
impl Default for General {
	fn default() -> Self {
		Self {
			stop_time: "30s".to_owned(),
			seed: 42,
			model_unblocked_syscall_latency: true,
			data_directory: None,
			log_level: Some("info".to_owned()),
		}
	}
}

/// Create a default 1 Gbit switch network.
impl Default for Network {
	fn default() -> Self {
		Self {
			graph: NetworkGraph {
				graph_type: "1_gbit_switch".to_owned(),
				inline: None,
			},
		}
	}
}

/// PCAP enabled by default.
impl Default for HostOptionDefaults {
	fn default() -> Self {
		Self {
			pcap_enabled: Some(true),
			pcap_capture_size: None,
		}
	}
}

/// Three-host config: tuwunel-server + alice-host + bob-host.
#[expect(clippy::too_many_arguments)]
pub fn three_host_config(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config_path: &Path,
	data_dir: &Path,
	subcommand: &str,
	stop_time: &str,
	seed: u32,
	alice_start: &str,
	bob_start: &str,
) -> ShadowConfig {
	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin path must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin path must be valid UTF-8")
		.to_owned();
	let config_str = config_path
		.to_str()
		.expect("config_path must be valid UTF-8")
		.to_owned();
	let data_str = data_dir
		.to_str()
		.expect("data_dir path must be valid UTF-8")
		.to_owned();

	let mut server_env = BTreeMap::new();
	server_env
		.insert("TUWUNEL_CONFIG".to_owned(), config_str);
	server_env
		.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let server_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: tuwunel_path,
			args: None,
			start_time: Some("1s".to_owned()),
			expected_final_state: Some(ProcessFinalState::Running(RunningVal::Running)),
			environment: Some(server_env),
			shutdown_time: None,
			shutdown_signal: Some("SIGTERM".to_owned()),
		}],
	};

	let alice_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path.clone(),
			args: Some(format!(
				"{subcommand} --server-url \
				 http://tuwunel-server:8448 --role alice"
			)),
			start_time: Some(alice_start.to_owned()),
			expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let bob_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path,
			args: Some(format!(
				"{subcommand} --server-url \
				 http://tuwunel-server:8448 --role bob"
			)),
			start_time: Some(bob_start.to_owned()),
			expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let mut hosts = BTreeMap::new();
	hosts.insert("tuwunel-server".to_owned(), server_host);
	hosts.insert("alice-host".to_owned(), alice_host);
	hosts.insert("bob-host".to_owned(), bob_host);

	ShadowConfig {
		general: General {
			stop_time: stop_time.to_owned(),
			seed,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: Network::default(),
		host_option_defaults: Some(HostOptionDefaults::default()),
		hosts,
	}
}

/// Load test config: one Shadow host per client, client-{NNN} naming.
#[expect(clippy::too_many_arguments)]
pub fn load_test_config(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config_path: &Path,
	data_dir: &Path,
	client_count: u32,
	topology: &TopologyFixture,
	stop_time: &str,
	seed: u32,
) -> ShadowConfig {
	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin path must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin path must be valid UTF-8")
		.to_owned();
	let config_str = config_path
		.to_str()
		.expect("config_path must be valid UTF-8")
		.to_owned();
	let data_str = data_dir
		.to_str()
		.expect("data_dir path must be valid UTF-8")
		.to_owned();

	let mut server_env = BTreeMap::new();
	server_env
		.insert("TUWUNEL_CONFIG".to_owned(), config_str);
	server_env
		.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let server_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: tuwunel_path,
			args: None,
			start_time: Some("1s".to_owned()),
			expected_final_state: Some(ProcessFinalState::Running(RunningVal::Running)),
			environment: Some(server_env),
			shutdown_time: None,
			shutdown_signal: Some("SIGTERM".to_owned()),
		}],
	};

	let mut hosts = BTreeMap::new();
	hosts.insert("tuwunel-server".to_owned(), server_host);

	// client-001: creator role, starts at 5s
	let creator_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path.clone(),
			args: Some(
				"load-test --server-url \
				 http://tuwunel-server:8448 \
				 --role creator --client-id 001"
					.to_owned(),
			),
			start_time: Some("5s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};
	hosts.insert("client-001".to_owned(), creator_host);

	// client-002 through client-{N}: joiner role, start at 10s
	for i in 2..=client_count {
		let joiner_host = Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: client_path.clone(),
				args: Some(format!(
					"load-test --server-url \
					 http://tuwunel-server:8448 \
					 --role joiner --client-id {i:03}"
				)),
				start_time: Some("10s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Exited { exited: 0 },
				),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		};
		hosts.insert(
			format!("client-{i:03}"),
			joiner_host,
		);
	}

	ShadowConfig {
		general: General {
			stop_time: stop_time.to_owned(),
			seed,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: topology.to_network(),
		host_option_defaults: Some(
			HostOptionDefaults::default(),
		),
		hosts,
	}
}

/// Network topology fixture for Shadow simulations.
#[derive(Clone, Debug)]
pub struct TopologyFixture {
	/// One-way latency in milliseconds (RTT = 2x this value for
	/// self-loop topology).
	pub latency_ms: u32,
	/// Packet loss rate as a fraction (0.0 to 1.0).
	pub packet_loss: f64,
	/// Download bandwidth (e.g., "5 Mbit").
	pub bandwidth_down: String,
	/// Upload bandwidth (e.g., "1 Mbit").
	pub bandwidth_up: String,
}

impl TopologyFixture {
	/// Slow mobile network: 150ms one-way latency (300ms RTT),
	/// 1% packet loss, 5 Mbit down / 1 Mbit up.
	pub fn slow_mobile() -> Self {
		Self {
			latency_ms: 150,
			packet_loss: 0.01,
			bandwidth_down: "5 Mbit".to_owned(),
			bandwidth_up: "1 Mbit".to_owned(),
		}
	}

	/// High latency link: 500ms one-way (1000ms RTT),
	/// no packet loss, 100 Mbit symmetric.
	pub fn high_latency() -> Self {
		Self {
			latency_ms: 500,
			packet_loss: 0.0,
			bandwidth_down: "100 Mbit".to_owned(),
			bandwidth_up: "100 Mbit".to_owned(),
		}
	}

	/// Lossy link: 50ms one-way (100ms RTT),
	/// 5% packet loss, 10 Mbit symmetric.
	pub fn lossy_link() -> Self {
		Self {
			latency_ms: 50,
			packet_loss: 0.05,
			bandwidth_down: "10 Mbit".to_owned(),
			bandwidth_up: "10 Mbit".to_owned(),
		}
	}

	/// Federation: two nodes, 100 Mbit symmetric, configurable
	/// inter-node latency and loss.
	pub fn federation(latency_ms: u32, packet_loss: f64) -> Self {
		Self {
			latency_ms,
			packet_loss,
			bandwidth_down: "100 Mbit".to_owned(),
			bandwidth_up: "100 Mbit".to_owned(),
		}
	}

	/// Override the one-way latency (ms).
	pub fn with_latency(mut self, ms: u32) -> Self {
		self.latency_ms = ms;
		self
	}

	/// Override the packet loss rate (0.0 to 1.0).
	pub fn with_loss(mut self, loss: f64) -> Self {
		self.packet_loss = loss;
		self
	}

	/// Override the download bandwidth (e.g., "10 Mbit").
	pub fn with_bandwidth_down(mut self, bw: &str) -> Self {
		self.bandwidth_down = bw.to_owned();
		self
	}

	/// Override the upload bandwidth (e.g., "5 Mbit").
	pub fn with_bandwidth_up(mut self, bw: &str) -> Self {
		self.bandwidth_up = bw.to_owned();
		self
	}

	/// Build GML graph string. packet_loss always included (Shadow
	/// requires it even when 0.0).
	pub fn to_gml(&self) -> String {
		format!(
			"graph [\n\
			 \x20 directed 0\n\
			 \x20 node [\n\
			 \x20   id 0\n\
			 \x20   host_bandwidth_down \"{bd}\"\n\
			 \x20   host_bandwidth_up \"{bu}\"\n\
			 \x20 ]\n\
			 \x20 edge [\n\
			 \x20   source 0\n\
			 \x20   target 0\n\
			 \x20   latency \"{lat} ms\"\n\
			 \x20   packet_loss {loss:.6}\n\
			 \x20 ]\n\
			 ]",
			bd = self.bandwidth_down,
			bu = self.bandwidth_up,
			lat = self.latency_ms,
			loss = self.packet_loss,
		)
	}

	/// Two-node federation GML: nodes 0 and 1 with self-loops
	/// plus cross-node edges at configured latency/loss.
	pub fn to_federation_gml(&self) -> String {
		format!(
			"graph [\n\
			 \x20 directed 0\n\
			 \x20 node [\n\
			 \x20   id 0\n\
			 \x20   host_bandwidth_down \"{bd}\"\n\
			 \x20   host_bandwidth_up \"{bu}\"\n\
			 \x20 ]\n\
			 \x20 node [\n\
			 \x20   id 1\n\
			 \x20   host_bandwidth_down \"{bd}\"\n\
			 \x20   host_bandwidth_up \"{bu}\"\n\
			 \x20 ]\n\
			 \x20 edge [\n\
			 \x20   source 0\n\
			 \x20   target 0\n\
			 \x20   latency \"1 ms\"\n\
			 \x20   packet_loss 0.000000\n\
			 \x20 ]\n\
			 \x20 edge [\n\
			 \x20   source 1\n\
			 \x20   target 1\n\
			 \x20   latency \"1 ms\"\n\
			 \x20   packet_loss 0.000000\n\
			 \x20 ]\n\
			 \x20 edge [\n\
			 \x20   source 0\n\
			 \x20   target 1\n\
			 \x20   latency \"{lat} ms\"\n\
			 \x20   packet_loss {loss:.6}\n\
			 \x20 ]\n\
			 \x20 edge [\n\
			 \x20   source 1\n\
			 \x20   target 0\n\
			 \x20   latency \"{lat} ms\"\n\
			 \x20   packet_loss {loss:.6}\n\
			 \x20 ]\n\
			 ]",
			bd = self.bandwidth_down,
			bu = self.bandwidth_up,
			lat = self.latency_ms,
			loss = self.packet_loss,
		)
	}

	/// Single-node Network from this topology.
	pub fn to_network(&self) -> Network {
		Network {
			graph: NetworkGraph {
				graph_type: "gml".to_owned(),
				inline: Some(self.to_gml()),
			},
		}
	}

	/// Build a complete Network struct for a two-node federation
	/// topology.
	pub fn to_federation_network(&self) -> Network {
		Network {
			graph: NetworkGraph {
				graph_type: "gml".to_owned(),
				inline: Some(self.to_federation_gml()),
			},
		}
	}
}

/// Like [`three_host_config`] but with custom network topology.
#[expect(clippy::too_many_arguments)]
pub fn three_host_config_with_topology(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config_path: &Path,
	data_dir: &Path,
	subcommand: &str,
	stop_time: &str,
	seed: u32,
	alice_start: &str,
	bob_start: &str,
	topology: &TopologyFixture,
) -> ShadowConfig {
	let mut config = three_host_config(
		tuwunel_bin,
		client_bin,
		config_path,
		data_dir,
		subcommand,
		stop_time,
		seed,
		alice_start,
		bob_start,
	);
	config.network = topology.to_network();
	config
}

/// Two-server federation config: server-a (node 0), server-b (node 1),
/// creator-host, joiner-host.
#[expect(clippy::too_many_arguments)]
pub fn federation_config(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config_a_path: &Path,
	config_b_path: &Path,
	data_dir: &Path,
	topology: &TopologyFixture,
	stop_time: &str,
	seed: u32,
) -> ShadowConfig {
	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin path must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin path must be valid UTF-8")
		.to_owned();
	let config_a_str = config_a_path
		.to_str()
		.expect("config_a_path must be valid UTF-8")
		.to_owned();
	let config_b_str = config_b_path
		.to_str()
		.expect("config_b_path must be valid UTF-8")
		.to_owned();
	let data_str = data_dir
		.to_str()
		.expect("data_dir path must be valid UTF-8")
		.to_owned();

	let mut env_a = BTreeMap::new();
	env_a.insert("TUWUNEL_CONFIG".to_owned(), config_a_str);
	env_a.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let mut env_b = BTreeMap::new();
	env_b.insert("TUWUNEL_CONFIG".to_owned(), config_b_str);
	env_b.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let mut hosts = BTreeMap::new();

	hosts.insert(
		"server-a".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: tuwunel_path.clone(),
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(RunningVal::Running),
				),
				environment: Some(env_a),
				shutdown_time: None,
				shutdown_signal: Some("SIGTERM".to_owned()),
			}],
		},
	);

	hosts.insert(
		"server-b".to_owned(),
		Host {
			network_node_id: 1,
			host_options: None,
			processes: vec![Process {
				path: tuwunel_path,
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(RunningVal::Running),
				),
				environment: Some(env_b),
				shutdown_time: None,
				shutdown_signal: Some("SIGTERM".to_owned()),
			}],
		},
	);

	hosts.insert(
		"creator-host".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: client_path.clone(),
				args: Some(
					"federation --server-url \
					 http://server-a:8448 --role creator"
						.to_owned(),
				),
				start_time: Some("10s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Exited { exited: 0 },
				),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		},
	);

	hosts.insert(
		"joiner-host".to_owned(),
		Host {
			network_node_id: 1,
			host_options: None,
			processes: vec![Process {
				path: client_path,
				args: Some(
					"federation --server-url \
					 http://server-b:8448 --role joiner"
						.to_owned(),
				),
				start_time: Some("15s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Exited { exited: 0 },
				),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		},
	);

	ShadowConfig {
		general: General {
			stop_time: stop_time.to_owned(),
			seed,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: topology.to_federation_network(),
		host_option_defaults: Some(HostOptionDefaults::default()),
		hosts,
	}
}

/// Restart persistence test: server shuts down at 30s, restarts at
/// 40s; writer and verifier clients.
#[expect(clippy::too_many_arguments)]
pub fn restart_config(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config_path: &Path,
	data_dir: &Path,
	stop_time: &str,
	seed: u32,
) -> ShadowConfig {
	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin path must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin path must be valid UTF-8")
		.to_owned();
	let config_str = config_path
		.to_str()
		.expect("config_path must be valid UTF-8")
		.to_owned();
	let data_str = data_dir
		.to_str()
		.expect("data_dir path must be valid UTF-8")
		.to_owned();

	let mut server_env = BTreeMap::new();
	server_env
		.insert("TUWUNEL_CONFIG".to_owned(), config_str);
	server_env
		.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let server_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![
			// First instance: runs from 1s, SIGTERM at 30s
			Process {
				path: tuwunel_path.clone(),
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: None,
				environment: Some(server_env.clone()),
				shutdown_time: Some("30s".to_owned()),
				shutdown_signal: Some("SIGTERM".to_owned()),
			},
			// Second instance: starts at 40s on same DB
			Process {
				path: tuwunel_path,
				args: None,
				start_time: Some("40s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(
						RunningVal::Running,
					),
				),
				environment: Some(server_env),
				shutdown_time: None,
				shutdown_signal: None,
			},
		],
	};

	let writer_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path.clone(),
			args: Some(
				"resilience --server-url \
				 http://tuwunel-server:8448 --role writer"
					.to_owned(),
			),
			start_time: Some("5s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let verifier_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path,
			args: Some(
				"resilience --server-url \
				 http://tuwunel-server:8448 --role verifier"
					.to_owned(),
			),
			start_time: Some("45s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let mut hosts = BTreeMap::new();
	hosts.insert(
		"tuwunel-server".to_owned(),
		server_host,
	);
	hosts.insert("writer-client".to_owned(), writer_host);
	hosts.insert(
		"verifier-client".to_owned(),
		verifier_host,
	);

	ShadowConfig {
		general: General {
			stop_time: stop_time.to_owned(),
			seed,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: Network::default(),
		host_option_defaults: Some(
			HostOptionDefaults::default(),
		),
		hosts,
	}
}

/// Partition/re-sync test: server2 restarts mid-simulation; three
/// client roles (setup, survivor, verifier).
#[expect(clippy::too_many_arguments)]
pub fn partition_resync_config(
	tuwunel_bin: &Path,
	client_bin: &Path,
	config1_path: &Path,
	config2_path: &Path,
	data_dir: &Path,
	topology: &TopologyFixture,
	scenario: &str,
	stop_time: &str,
	seed: u32,
) -> ShadowConfig {
	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin path must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin path must be valid UTF-8")
		.to_owned();
	let config1_str = config1_path
		.to_str()
		.expect("config1_path must be valid UTF-8")
		.to_owned();
	let config2_str = config2_path
		.to_str()
		.expect("config2_path must be valid UTF-8")
		.to_owned();
	let data_str = data_dir
		.to_str()
		.expect("data_dir path must be valid UTF-8")
		.to_owned();

	let mut env1 = BTreeMap::new();
	env1.insert("TUWUNEL_CONFIG".to_owned(), config1_str);
	env1.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let mut env2 = BTreeMap::new();
	env2.insert("TUWUNEL_CONFIG".to_owned(), config2_str);
	env2.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let server1_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: tuwunel_path.clone(),
			args: None,
			start_time: Some("1s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Running(
					RunningVal::Running,
				),
			),
			environment: Some(env1),
			shutdown_time: None,
			shutdown_signal: Some("SIGTERM".to_owned()),
		}],
	};

	let server2_host = Host {
		network_node_id: 1,
		host_options: None,
		processes: vec![
			// First instance: runs from 1s, SIGTERM at 30s
			Process {
				path: tuwunel_path.clone(),
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: None,
				environment: Some(env2.clone()),
				shutdown_time: Some("30s".to_owned()),
				shutdown_signal: Some("SIGTERM".to_owned()),
			},
			// Second instance: restarts at 40s on same DB
			Process {
				path: tuwunel_path,
				args: None,
				start_time: Some("40s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(
						RunningVal::Running,
					),
				),
				environment: Some(env2),
				shutdown_time: None,
				shutdown_signal: None,
			},
		],
	};

	let setup_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path.clone(),
			args: Some(format!(
				"{scenario} --server-url \
				 http://server1:8448 --role creator \
				 --remote-server server2 --remote-url \
				 http://server2:8448"
			)),
			start_time: Some("10s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let survivor_host = Host {
		network_node_id: 0,
		host_options: None,
		processes: vec![Process {
			path: client_path.clone(),
			args: Some(format!(
				"{scenario} --server-url \
				 http://server1:8448 --role survivor"
			)),
			start_time: Some("35s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let verifier_host = Host {
		network_node_id: 1,
		host_options: None,
		processes: vec![Process {
			path: client_path,
			args: Some(format!(
				"{scenario} --server-url \
				 http://server2:8448 --role verifier"
			)),
			start_time: Some("55s".to_owned()),
			expected_final_state: Some(
				ProcessFinalState::Exited { exited: 0 },
			),
			environment: None,
			shutdown_time: None,
			shutdown_signal: None,
		}],
	};

	let mut hosts = BTreeMap::new();
	hosts.insert("server1".to_owned(), server1_host);
	hosts.insert("server2".to_owned(), server2_host);
	hosts.insert("setup-client".to_owned(), setup_host);
	hosts.insert(
		"survivor-client".to_owned(),
		survivor_host,
	);
	hosts.insert(
		"verifier-client".to_owned(),
		verifier_host,
	);

	ShadowConfig {
		general: General {
			stop_time: stop_time.to_owned(),
			seed,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: topology.to_federation_network(),
		host_option_defaults: Some(
			HostOptionDefaults::default(),
		),
		hosts,
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn test_federation_topology_gml() {
		let topology = TopologyFixture::federation(50, 0.03);

		// Verify constructor sets the right values
		assert_eq!(topology.latency_ms, 50);
		assert!((topology.packet_loss - 0.03).abs() < f64::EPSILON);
		assert_eq!(topology.bandwidth_down, "100 Mbit");
		assert_eq!(topology.bandwidth_up, "100 Mbit");

		let gml = topology.to_federation_gml();

		// Must have two nodes
		let node_count = gml.matches("node [").count();
		assert_eq!(
			node_count, 2,
			"Expected 2 nodes in federation GML, got {node_count}"
		);

		// Must have 4 edges: 2 self-loops + 2 cross-node (Shadow
		// requires self-loop edges for shortest-path computation)
		let edge_count = gml.matches("edge [").count();
		assert_eq!(
			edge_count, 4,
			"Expected 4 edges in federation GML (2 self-loops + \
			 2 cross-node), got {edge_count}"
		);

		// Must contain both node IDs
		assert!(
			gml.contains("id 0"),
			"Federation GML missing node id 0"
		);
		assert!(
			gml.contains("id 1"),
			"Federation GML missing node id 1"
		);

		// Must contain the configured latency value
		assert!(
			gml.contains("latency \"50 ms\""),
			"Federation GML missing latency 50 ms. GML:\n{gml}"
		);

		// Must contain the configured packet loss value (formatted as
		// float with 6 decimal places for Shadow GML parser
		// compatibility)
		assert!(
			gml.contains("packet_loss 0.030000"),
			"Federation GML missing packet_loss 0.030000. GML:\n{gml}"
		);

		// Verify different latency/loss values propagate
		let topology2 = TopologyFixture::federation(200, 0.1);
		let gml2 = topology2.to_federation_gml();
		assert!(
			gml2.contains("latency \"200 ms\""),
			"Federation GML should contain latency 200 ms"
		);
		assert!(
			gml2.contains("packet_loss 0.100000"),
			"Federation GML should contain packet_loss 0.100000"
		);
	}
}
