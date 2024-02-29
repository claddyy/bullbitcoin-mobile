import 'package:bb_mobile/_model/transaction.dart';
import 'package:bb_mobile/_pkg/boltz/swap.dart';
import 'package:bb_mobile/_pkg/consts/configs.dart';
import 'package:bb_mobile/_pkg/storage/hive.dart';
import 'package:bb_mobile/_pkg/storage/secure_storage.dart';
import 'package:bb_mobile/_pkg/wallet/address.dart';
import 'package:bb_mobile/_pkg/wallet/repository.dart';
import 'package:bb_mobile/_pkg/wallet/sensitive/repository.dart';
import 'package:bb_mobile/_pkg/wallet/transaction.dart';
import 'package:bb_mobile/home/bloc/home_cubit.dart';
import 'package:bb_mobile/network/bloc/network_cubit.dart';
import 'package:bb_mobile/settings/bloc/settings_cubit.dart';
import 'package:bb_mobile/swap/bloc/swap_state.dart';
import 'package:bb_mobile/swap/bloc/watchtxs_bloc.dart';
import 'package:bb_mobile/swap/bloc/watchtxs_event.dart';
import 'package:bb_mobile/wallet/bloc/event.dart';
import 'package:boltz_dart/boltz_dart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class SwapCubit extends Cubit<SwapState> {
  SwapCubit({
    required this.hiveStorage,
    required this.secureStorage,
    required this.walletAddress,
    required this.walletRepository,
    required this.walletSensitiveRepository,
    required this.settingsCubit,
    required this.networkCubit,
    required this.swapBoltz,
    required this.walletTx,
    required this.walletTransaction,
    required this.watchTxsBloc,
    required this.homeCubit,
  }) : super(const SwapState());

  final SettingsCubit settingsCubit;
  final WalletAddress walletAddress;
  final HiveStorage hiveStorage;
  final SecureStorage secureStorage;
  final WalletRepository walletRepository;
  final WalletSensitiveRepository walletSensitiveRepository;
  final WalletTx walletTransaction;
  final NetworkCubit networkCubit;
  final SwapBoltz swapBoltz;
  final WalletTx walletTx;
  final WatchTxsBloc watchTxsBloc;
  final HomeCubit homeCubit;

  void createBtcLightningSwap({
    required String walletId,
    required int amount,
    String? label,
  }) async {
    if (!networkCubit.state.testnet) return;
    // why are we regetting bloc?
    // if we want the latest status then we should just pass wallet.id
    // and get the relavent WalletBloc
    final bloc = homeCubit.state.getWalletBlocById(walletId);
    if (bloc == null) return;

    final outAmount = amount;
    if (outAmount < 50000 || outAmount > 25000000) {
      emit(
        state.copyWith(
          errCreatingSwapInv: 'Amount should be greater than 50000 and less than 25000000 sats',
          generatingSwapInv: false,
        ),
      );
      return;
    }

    emit(state.copyWith(generatingSwapInv: true, errCreatingSwapInv: ''));
    final (seed, errReadingSeed) = await walletSensitiveRepository.readSeed(
      fingerprintIndex: bloc.state.wallet!.getRelatedSeedStorageString(),
      secureStore: secureStorage,
    );
    if (errReadingSeed != null) {
      emit(state.copyWith(errCreatingSwapInv: errReadingSeed.toString(), generatingSwapInv: false));
      return;
    }
    final (fees, errFees) = await swapBoltz.getFeesAndLimits(
      boltzUrl: boltzTestnet,
      outAmount: outAmount,
    );
    if (errFees != null) {
      emit(state.copyWith(errCreatingSwapInv: errFees.toString(), generatingSwapInv: false));
      return;
    }

    final (swap, errCreatingInv) = await swapBoltz.receive(
      mnemonic: seed!.mnemonic,
      index: bloc.state.wallet!.swapKeyIndex,
      outAmount: outAmount,
      network: Chain.Testnet,
      electrumUrl: networkCubit.state.getNetworkUrl(),
      boltzUrl: boltzTestnet,
      pairHash: fees!.btcPairHash,
    );
    if (errCreatingInv != null) {
      emit(state.copyWith(errCreatingSwapInv: errCreatingInv.toString(), generatingSwapInv: false));
      return;
    }

    final updatedSwap = swap!.copyWith(
      boltzFees: fees.btcReverse.boltzFees,
      lockupFees: fees.btcReverse.lockupFees,
      claimFees: fees.btcReverse.claimFeesEstimate,
    );

    emit(
      state.copyWith(
        generatingSwapInv: false,
        errCreatingSwapInv: '',
        swapTx: updatedSwap,
      ),
    );

    _saveSwapInvoiceToWallet(
      swapTx: updatedSwap,
      label: label,
      walletId: walletId,
    );
  }

  void _saveSwapInvoiceToWallet({
    required String walletId,
    required SwapTx swapTx,
    String? label,
  }) async {
    final bloc = homeCubit.state.getWalletBlocById(walletId);
    if (bloc == null) return;

    final wallet = bloc.state.wallet;
    if (wallet == null) return;

    final swapKeyIndex = wallet.swapKeyIndex + 1;

    // final tx = Transaction.fromSwapTx(event.swapTx).copyWith(
    //   isSwap: true,
    //   swapIndex: wallet.swapTxCount,
    //   label: event.label,
    // );

    final (updatedWallet, err) = await walletTx.addSwapTxToWallet(
      wallet: wallet.copyWith(
        swapKeyIndex: swapKeyIndex,
      ),
      swapTx: swapTx,
    );
    if (err != null) {
      emit(state.copyWith(errCreatingSwapInv: err.toString(), generatingSwapInv: false));
      return;
    }

    bloc.add(
      UpdateWallet(
        updatedWallet,
        updateTypes: [UpdateWalletTypes.swaps],
      ),
    );

    // await Future.delayed(500.ms);
    homeCubit.updateSelectedWallet(bloc);
    // await Future.delayed(500.ms);
    watchTxsBloc.add(WatchWalletTxs(walletId: walletId));
  }

  void resetToNewLnInvoice() => emit(state.copyWith(swapTx: null));
}
