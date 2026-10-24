import 'package:flutter/material.dart';

class LocalAvatarWidget extends StatelessWidget {
  final String uid;
  final String role; // 'expert' or 'user'
  final double radius;
  final String? avatarUrl;
  final int avatarIndex;

  const LocalAvatarWidget({
    super.key,
    required this.uid,
    required this.role,
    this.radius = 24.0,
    this.avatarUrl,
    this.avatarIndex = 1,
  });

  @override
  Widget build(BuildContext context) {
    final double size = radius * 2;
    final int safeIndex = (avatarIndex >= 1 && avatarIndex <= 6) ? avatarIndex : 1;
    final String assetPath = role == 'expert'
        ? 'assets/avatars/female_$safeIndex.png'
        : 'assets/avatars/male_$safeIndex.png';

    final hasNetworkImage = avatarUrl != null && avatarUrl!.trim().isNotEmpty;

    if (hasNetworkImage) {
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Image.network(
            avatarUrl!.trim(),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Image.asset(
                assetPath,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    width: size,
                    height: size,
                    color: Colors.grey.shade200,
                    child: Icon(
                      role == 'expert' ? Icons.face_3_rounded : Icons.person_rounded,
                      size: radius * 1.2,
                      color: Colors.grey.shade400,
                    ),
                  );
                },
              );
            },
          ),
        ),
      );
    }

    return ClipOval(
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: size,
            height: size,
            color: Colors.grey.shade200,
            child: Icon(
              role == 'expert' ? Icons.face_3_rounded : Icons.person_rounded,
              size: radius * 1.2,
              color: Colors.grey.shade400,
            ),
          );
        },
      ),
    );
  }
}
