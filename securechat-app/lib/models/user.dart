class User {
  final String userId;
  final String displayName;
  final String publicKey;
  final String signPublic;

  const User({
    required this.userId,
    required this.displayName,
    required this.publicKey,
    required this.signPublic,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        userId: json['user_id'] as String,
        displayName: json['display_name'] as String,
        publicKey: json['public_key'] as String,
        signPublic: json['sign_public'] as String,
      );

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'display_name': displayName,
        'public_key': publicKey,
        'sign_public': signPublic,
      };
}
