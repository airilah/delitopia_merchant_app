import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/core/constants/app_constants.dart';
import 'src/screens/merchant_webview_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set transparent status bar and dark icons for clean top view
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const DelitopiaMerchantApp());
}

class DelitopiaMerchantApp extends StatelessWidget {
  const DelitopiaMerchantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(AppConstants.primaryColorHex),
          primary: const Color(AppConstants.primaryColorHex),
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
        ),
      ),
      home: const MerchantWebViewScreen(),
    );
  }
}
