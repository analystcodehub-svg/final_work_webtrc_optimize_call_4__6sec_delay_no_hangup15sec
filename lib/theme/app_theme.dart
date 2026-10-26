import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // New Premium Colors (Midnight Blue & Sunset Orange)
  static const Color primaryBlue = Color(0xFF1E1B4B); // Midnight Blue
  static const Color secondaryOrange = Color(0xFFF97316); // Sunset Orange
  static const Color textBlack = Color(0xFF0F172A);
  static const Color textGrey = Color(0xFF64748B);
  static const Color bgWhite = Colors.white;
  static const Color bgLight = Color(0xFFF8FAFC);
  static const Color containerWhite = Color(0xFFFFFFFF);
  static const Color inputBg = Color(0xFFF1F5F9);
  static const Color borderGrey = Color(0xFFE2E8F0);
  static const Color lightBlue = Color(0xFFE0E7FF);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: bgWhite,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        secondary: secondaryOrange,
        surface: bgWhite,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textBlack,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: IconThemeData(color: primaryBlue),
        titleTextStyle: TextStyle(
          color: textBlack,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Color(0xFFE2E8F0),
        ),
      ),
      textTheme: GoogleFonts.poppinsTextTheme().copyWith(
        headlineMedium: GoogleFonts.poppins(
          color: textBlack,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        titleLarge: GoogleFonts.poppins(
          color: textBlack,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: GoogleFonts.poppins(
          color: textBlack,
          fontSize: 16,
          fontWeight: FontWeight.normal,
        ),
        bodyMedium: GoogleFonts.poppins(
          color: textGrey,
          fontSize: 14,
          fontWeight: FontWeight.normal,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFCCCCCC),
          disabledForegroundColor: const Color(0xFF888888),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), // Sharper corners
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), // Sharper corners
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 1.5),
        ),
        hintStyle: GoogleFonts.poppins(
          color: textGrey,
          fontSize: 16,
        ),
      ),
    );
  }
}
