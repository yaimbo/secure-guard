import 'package:bcrypt/bcrypt.dart';

void main(List<String> args) {
  final password = args.isNotEmpty ? args[0] : 'Thegreenfrog';
  final hash = BCrypt.hashpw(password, BCrypt.gensalt());
  print(hash);
}
