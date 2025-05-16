import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'src/providers/providers.dart';
import 'src/screens/login_screen.dart';
import 'src/screens/room_list_screen.dart';
import 'src/screens/chat_screen.dart';

/// GoRouter configuration driven by auth state.
///
/// Redirects unauthenticated users to /login and authenticated users
/// away from /login to /rooms.
final routerProvider = Provider<GoRouter>((ref) {
  final isLoggedIn = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final loggingIn = state.matchedLocation == '/login';
      if (!isLoggedIn && !loggingIn) return '/login';
      if (isLoggedIn && loggingIn) return '/rooms';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/rooms',
        builder: (context, state) => const RoomListScreen(),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (context, state) => ChatScreen(
          roomId: state.pathParameters['roomId']!,
        ),
      ),
    ],
  );
});
