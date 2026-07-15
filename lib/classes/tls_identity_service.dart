import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class TlsIdentity {
  const TlsIdentity({
    required this.certificatePath,
    required this.privateKeyPath,
    required this.certificatePem,
    required this.fingerprint,
  });

  final String certificatePath;
  final String privateKeyPath;
  final String certificatePem;
  final String fingerprint;
}

class TlsIdentityService {
  TlsIdentityService._();

  static const _certificateFileName = 'device.crt';
  static const _privateKeyFileName = 'device.key';

  static Future<TlsIdentity> getOrCreateIdentity() async {
    final directory = await _identityDirectory();
    final certFile = File('${directory.path}/$_certificateFileName');
    final keyFile = File('${directory.path}/$_privateKeyFileName');

    if (await certFile.exists() && await keyFile.exists()) {
      final certPem = await certFile.readAsString();
      if (certPem.trim().isNotEmpty) {
        return TlsIdentity(
          certificatePath: certFile.path,
          privateKeyPath: keyFile.path,
          certificatePem: certPem,
          fingerprint: certificateFingerprint(certPem),
        );
      }
    }

    return _generateIdentity(certFile: certFile, keyFile: keyFile);
  }

  static Future<TlsIdentity> resetIdentity() async {
    final directory = await _identityDirectory();
    return _generateIdentity(
      certFile: File('${directory.path}/$_certificateFileName'),
      keyFile: File('${directory.path}/$_privateKeyFileName'),
    );
  }

  static Future<String> writeTrustedPeerCertificate({
    required String peerId,
    required String certificatePem,
  }) async {
    final directory = await _identityDirectory();
    final safePeerId = peerId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final file = File('${directory.path}/trusted_$safePeerId.crt');
    await file.writeAsString(certificatePem, flush: true);
    return file.path;
  }

  static String certificateFingerprint(String certificatePem) {
    final normalizedPem = certificatePem.replaceAll('\r\n', '\n');
    final base64Body = normalizedPem
        .split('\n')
        .where((line) => line.isNotEmpty && !line.startsWith('---'))
        .join();
    final derBytes = base64Decode(base64Body);
    return sha256.convert(Uint8List.fromList(derBytes)).toString();
  }

  static Future<Directory> _identityDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory('${supportDirectory.path}/tls_identity');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<TlsIdentity> _generateIdentity({
    required File certFile,
    required File keyFile,
  }) async {
    final keyPair = CryptoUtils.generateRSAKeyPair();
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      {
        'CN': 'Flashbyte Device',
        'O': 'Flashbyte',
        'OU': '',
        'L': '',
        'S': '',
        'C': '',
      },
      privateKey,
      publicKey,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      365 * 10,
    );
    final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(
      privateKey,
    );

    await certFile.writeAsString(certificatePem, flush: true);
    await keyFile.writeAsString(privateKeyPem, flush: true);

    return TlsIdentity(
      certificatePath: certFile.path,
      privateKeyPath: keyFile.path,
      certificatePem: certificatePem,
      fingerprint: certificateFingerprint(certificatePem),
    );
  }
}
