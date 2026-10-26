import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../providers/app_state.dart';
import '../services/user_database_service.dart';
import 'payment_history_screen.dart';

class RechargePackage {
  final double amount;
  final int coins;
  final int bonusCoins;
  final String? badge;
  final String? extraText;
  final Color? badgeColor;

  const RechargePackage({
    required this.amount,
    required this.coins,
    required this.bonusCoins,
    this.badge,
    this.extraText,
    this.badgeColor,
  });

  String get productId => 'sajnire_recharge_${amount.toInt()}';
}

class WalletRechargeScreen extends StatefulWidget {
  const WalletRechargeScreen({super.key});

  @override
  State<WalletRechargeScreen> createState() => _WalletRechargeScreenState();
}

class _WalletRechargeScreenState extends State<WalletRechargeScreen> {
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  // Recharge packages matching user's screen + Rs20 option added
  final List<RechargePackage> _packages = const [
    RechargePackage(amount: 20.0, coins: 200, bonusCoins: 0, extraText: "Starter Pack"),
    RechargePackage(amount: 50.0, coins: 500, bonusCoins: 30, extraText: "+6% Extra"),
    RechargePackage(amount: 100.0, coins: 1000, bonusCoins: 150, extraText: "+15% Extra"),
    RechargePackage(
      amount: 140.0,
      coins: 1400,
      bonusCoins: 280,
      extraText: "+20% Extra",
      badge: "Value Pack",
      badgeColor: Color(0xFFEF4444),
    ),
    RechargePackage(amount: 200.0, coins: 2000, bonusCoins: 500, extraText: "+25% Extra"),
    RechargePackage(
      amount: 300.0,
      coins: 3000,
      bonusCoins: 1050,
      extraText: "+35% Extra",
      badge: "Popular",
      badgeColor: Color(0xFFEF4444),
    ),
    RechargePackage(amount: 500.0, coins: 5000, bonusCoins: 1750, extraText: "+35% Extra"),
    RechargePackage(amount: 900.0, coins: 9000, bonusCoins: 3150, extraText: "+35% Extra"),
    RechargePackage(amount: 1900.0, coins: 19000, bonusCoins: 7600, extraText: "+40% Extra"),
  ];

  int _selectedPackageIndex = 3; // Default selection (₹140 Value Pack)
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initInAppPurchase();
  }

  void _initInAppPurchase() {
    final Stream<List<PurchaseDetails>> purchaseUpdated = InAppPurchase.instance.purchaseStream;
    _subscription = purchaseUpdated.listen((purchaseDetailsList) {
      _listenToPurchaseUpdated(purchaseDetailsList);
    }, onDone: () {
      _subscription?.cancel();
    }, onError: (error) {
      debugPrint("In-App Purchase Stream Error: $error");
      if (mounted) {
        _showSnackBar("Purchase Error: $error", isError: true);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  double get _payableAmount => _packages[_selectedPackageIndex].amount;
  int get _totalCoinsCredited => _packages[_selectedPackageIndex].coins + _packages[_selectedPackageIndex].bonusCoins;

  void _listenToPurchaseUpdated(List<PurchaseDetails> purchaseDetailsList) async {
    for (var purchaseDetails in purchaseDetailsList) {
      if (purchaseDetails.status == PurchaseStatus.pending) {
        if (mounted) setState(() => _isLoading = true);
      } else {
        if (purchaseDetails.status == PurchaseStatus.error) {
          if (mounted) setState(() => _isLoading = false);
          _showSnackBar("Purchase Error: ${purchaseDetails.error?.message}", isError: true);
        } else if (purchaseDetails.status == PurchaseStatus.purchased ||
                   purchaseDetails.status == PurchaseStatus.restored) {
          await _syncWallet(
            gateway: 'Google Play',
            txnId: purchaseDetails.purchaseID ?? 'gplay_${DateTime.now().millisecondsSinceEpoch}',
          );
        }
        if (purchaseDetails.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(purchaseDetails);
        }
      }
    }
  }

  Future<void> _syncWallet({required String gateway, required String txnId}) async {
    final appState = context.read<AppState>();
    final myUid = appState.uid;
    if (myUid.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      // 1. Credit coins in RTDB using atomic transaction
      await UserDatabaseService.instance.addUserCoins(myUid, _totalCoinsCredited);

      // 2. Fetch fresh user data from RTDB to guarantee 100% accurate balance sync (prevents double-addition)
      final updatedData = await UserDatabaseService.instance.getUser(myUid);
      if (updatedData != null && updatedData['coinBalance'] != null) {
        final freshCoins = (updatedData['coinBalance'] as num).toInt();
        appState.setCoinBalance(freshCoins);
      }

      // 3. Save recharge history in Firestore as strictly requested
      final rechargeDocRef = FirebaseFirestore.instance.collection('recharge_history').doc(txnId);
      await rechargeDocRef.set({
        'buyer_name': myUid,
        'userId': myUid,
        'amount': _payableAmount,
        'coinsCredited': _totalCoinsCredited,
        'gateway': gateway,
        'status': 'success',
        'timestamp': FieldValue.serverTimestamp(),
        'txnId': txnId,
      });

      if (mounted) {
        setState(() => _isLoading = false);
        // Directly pop recharge screen back to previous screen (remove green dialog popup)
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment Successful! ₹${_payableAmount.toStringAsFixed(0)} added to wallet.'),
            backgroundColor: const Color(0xFF16A34A),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error syncing wallet recharge: $e");
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar("Payment succeeded but failed to sync balance: $e", isError: true);
      }
    }
  }

  Future<void> _buyProduct() async {
    setState(() => _isLoading = true);
    final selectedPkg = _packages[_selectedPackageIndex];
    final productId = selectedPkg.productId;

    try {
      final bool available = await InAppPurchase.instance.isAvailable();
      if (!available) {
        _handlePlayStoreUnavailable(productId);
        return;
      }

      final ProductDetailsResponse response = await InAppPurchase.instance.queryProductDetails({productId});

      if (response.notFoundIDs.isNotEmpty || response.productDetails.isEmpty) {
        // Product ID not yet created or active in Google Play Console
        if (mounted) {
          setState(() => _isLoading = false);
          _showProductNotConfiguredDialog(productId, selectedPkg);
        }
        return;
      }

      final ProductDetails productDetails = response.productDetails.first;
      final PurchaseParam purchaseParam = PurchaseParam(productDetails: productDetails);

      await InAppPurchase.instance.buyConsumable(purchaseParam: purchaseParam, autoConsume: true);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar("Failed to launch billing: $e", isError: true);
      }
    }
  }

  void _handlePlayStoreUnavailable(String productId) {
    if (mounted) {
      setState(() => _isLoading = false);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Google Play Billing Unavailable'),
          content: const Text(
            'Google Play Store is not available or supported on this device/emulator.\n\n'
            'In debug/testing mode, you can use Test Recharge.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            if (kDebugMode)
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _syncWallet(
                    gateway: 'Test Simulation',
                    txnId: 'sim_${DateTime.now().millisecondsSinceEpoch}',
                  );
                },
                child: const Text('Test Recharge'),
              ),
          ],
        ),
      );
    }
  }

  void _showProductNotConfiguredDialog(String productId, RechargePackage pkg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Play Console Product Pending'),
        content: Text(
          'Product "$productId" (₹${pkg.amount.toStringAsFixed(0)}) is not yet published in Google Play Console (Monetize > In-app products).\n\n'
          'Once you create it in Play Console with ID: $productId, Google Play will process payments directly.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
          if (kDebugMode)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _syncWallet(
                  gateway: 'Debug Test',
                  txnId: 'debug_${DateTime.now().millisecondsSinceEpoch}',
                );
              },
              child: const Text('Simulate (Debug)'),
            ),
        ],
      ),
    );
  }


  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildTrustBadge(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF64748B)),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final coinBalance = context.watch<AppState>().coinBalance;
    const Color bgColor = Color(0xFFF9F5FA);
    final selectedPackage = _packages[_selectedPackageIndex];

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Color(0xFFE2E8F0),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF312E81), Color(0xFF1E1B4B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Wallet', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0, top: 10.0, bottom: 10.0),
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PaymentHistoryScreen()),
                );
              },
              icon: const Icon(Icons.swap_vert_rounded, size: 16, color: Colors.white),
              label: const Text('Transactions', style: TextStyle(color: Colors.white, fontSize: 13)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white70),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          )
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Balance Card
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'My Balance',
                        style: TextStyle(color: Color(0xFF64748B), fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '₹${(coinBalance / 10).toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Color(0xFF3B82F6),
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Title
                const Text(
                  'Add Balance to Wallet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 14),

                // 2-Column Grid of packages (matching Image 2)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: _packages.length,
                  itemBuilder: (context, index) {
                    final package = _packages[index];
                    final isSelected = _selectedPackageIndex == index;

                    return GestureDetector(
                      onTap: () => setState(() => _selectedPackageIndex = index),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFEFF6FF) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF3B82F6) : Colors.grey.shade200,
                            width: isSelected ? 2.0 : 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.02),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            // Badge on top if present
                            if (package.badge != null)
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: package.badgeColor ?? const Color(0xFFEF4444),
                                      borderRadius: const BorderRadius.only(
                                        bottomLeft: Radius.circular(8),
                                        bottomRight: Radius.circular(8),
                                      ),
                                    ),
                                    child: Text(
                                      package.badge!,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                            // Main content
                            Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (package.badge != null) const SizedBox(height: 8),
                                  Text(
                                    '₹${package.amount.toStringAsFixed(0)}',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      color: isSelected ? const Color(0xFF1E3A8A) : const Color(0xFF0F172A),
                                    ),
                                  ),
                                  if (package.extraText != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      package.extraText!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF10B981),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // Trust Badges Row (Verified Experts, 100% Safe, Bank Approved)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildTrustBadge(Icons.verified_user_outlined, 'Verified Experts'),
                      _buildTrustBadge(Icons.shield_outlined, '100% Safe'),
                      _buildTrustBadge(Icons.account_balance_outlined, 'Bank Approved'),
                    ],
                  ),
                ),

                const SizedBox(height: 120), // Bottom padding for sticky button
              ],
            ),
          ),

          // Bottom Action Button
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.only(top: 14, bottom: 20, left: 20, right: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((selectedPackage.bonusCoins / 10) > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Get ₹${(selectedPackage.bonusCoins / 10).toStringAsFixed(0)} Extra cashback on this pack',
                        style: const TextStyle(
                          color: Color(0xFF10B981),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _buyProduct,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316), // Sunset Orange matching original CTA
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 2,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                            )
                          : Text(
                              'Add Balance  •  ₹${selectedPackage.amount.toStringAsFixed(0)}',
                              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
