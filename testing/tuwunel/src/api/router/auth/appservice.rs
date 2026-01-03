use ruma::{OwnedUserId, UserId};
use tuwunel_core::{Err, Result};
use tuwunel_service::{Services, appservice::RegistrationInfo};

use super::{Auth, Request};

pub(super) async fn auth_appservice(
	services: &Services,
	request: &Request,
	info: Box<RegistrationInfo>,
) -> Result<Auth> {
	let user_id_default = || {
		UserId::parse_with_server_name(
			info.registration.sender_localpart.as_str(),
			services.globals.server_name(),
		)
	};

	let Ok(user_id) = request
		.query
		.user_id
		.as_deref()
		.map_or_else(user_id_default, OwnedUserId::parse)
	else {
		return Err!(Request(InvalidUsername("Username is invalid.")));
	};

	if !info.is_user_match(&user_id) {
		return Err!(Request(Exclusive("User is not in namespace.")));
	}

	Ok(Auth {
		sender_user: Some(user_id),
		appservice_info: Some(*info),
		..Auth::default()
	})
}
