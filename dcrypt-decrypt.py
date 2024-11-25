#!/usr/bin/env python
#
# Copyright (c) 2024 Dovecot authors, see the included COPYING file
#
# See COPYING for details on license and warranty.
#
# Requirements:
# asn1>=2.7.1
# cryptography>=42.0.8
#

# Suppress misc pylint warnings globally.
# pylint: disable=too-many-lines
# pylint: disable=invalid-name,missing-module-docstring,too-many-arguments

import argparse
import ssl
import struct
import sys
from enum import Flag

import asn1
from cryptography.hazmat._oid import ObjectIdentifier
from cryptography.hazmat.primitives import (ciphers, hashes, hmac, padding,
                                            serialization)
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric import \
    padding as asymmetric_padding
from cryptography.hazmat.primitives.asymmetric import rsa, x25519
from cryptography.hazmat.primitives.ciphers import aead
from cryptography.hazmat.primitives.kdf import pbkdf2

TOOL_NAME = "dcrypt-decrypt"
HELP_TEXT = f"""Usage: {TOOL_NAME} <Options>

Decrypt a file.
This script requires any combination of 'info' and 'key' to work. If neither
options are given, it will yield an error.

Options:
    -f, --file  FILE  File to read. By default the file is read from stdin.
    -i, --info        Show information about file.
    -k, --key   KEY   Private key to decrypt file.
    -w, --write FILE  File to write contents instead of stdout.

        --warn        In case the message integrity check fails, warn instead
                      of erroring out.

    -h, --help        Print this help text and exit.
"""


def print_help_and_exit(status_code=0, msg=""):
    """
    Print the usage/help text with an optional error_msg.
    Exit this program with the given status_code.
    """
    sys.stdout.write(f"{HELP_TEXT}")
    if msg:
        sys.stdout.write(msg)
    sys.exit(status_code)


def pad_data(data, length, pad_bytes=b'\x00'):
    """
    Make sure the given data is padded to match the given length.
    """
    out = data
    remainder = len(data) % length
    if remainder > 0:
        required_padding = length - remainder
        out += (pad_bytes * required_padding)
    return out


def format_line(key, val=None, level=1):
    """
    Format the given key/value data consolidatedly.
    The key is padded in a specific width, currently 15 characters wide.
    The value is appended verbatim.
    The key can be indented further by giving a level. This level will add a
    prefix char, i.e. '-', prefixed by the level times 2 worth of spaces.

    Example:
        format_line("Hello", "World")
        -> "Hello          : World"
        format_line("Hello", "World", level=2)
        -> "  - Hello      : World"
        format_line("Hello", "World", level=6)
        -> "          - Hello: World"
    """

    prefix = ''
    width = 15
    if level > 1:
        indent = level * 2
        prefix = f"{'- ':>{indent}}"
        width -= indent
    return f"{prefix}{key:{width}}: {val if val else f'{0:032}'}"


class DecryptionError(ValueError):
    """
    Special type of ValueError to denote errors with the decryption operation.
    """


class ASN1Object:
    """
    Class to handle ASN1 objects.
    Allows reading an OID and looking up its object, as well as its algorithm,
    hash, block-size and mode depending on object type.
    """

    # This class is a wrapper around ASN1 objects. Most of its attributes are
    # handling access to individual attributes of different types of ASN1
    # objects. Disable the relevant pylint message.
    # pylint: disable=too-many-instance-attributes

    _SPECIAL_OIDS = {
        "1.2.840.113549.1.9.16.3.18": (1018, "ChaCha20-Poly1305",
                                       "ChaCha20-Poly1305"),
    }

    def __init__(self, oid):
        (self.nid, self.sn, self.ln, self.oid) = self.oid2obj(oid)
        self.is_chacha = "chacha20" in self.ln.lower()
        splits = self.ln.split('-')
        self.__algo = ''.join(splits[:-1])
        self.__mode = splits[-1]
        try:
            self.__keysize = int(splits[1]) // 8
        except (IndexError, ValueError):
            self.__keysize = 0

    def oid2obj(self, oid):
        """
        Convert the OID to the appropriate object.
        """

        if oid in self._SPECIAL_OIDS:
            return self._SPECIAL_OIDS[oid] + (oid,)
        # This function is only available with the underscore-prefixed path.
        # Suppress the pylint-warning locally.
        # pylint: disable=protected-access
        return ssl._txt2obj(oid)

    @property
    def keysize(self):
        """
        Return keysize by given algorithm.
        For ChaCha20 this is a fixed value of 32.
        """
        if self.is_chacha:
            return 32
        return self.__keysize

    @property
    def algorithm(self):
        """
        Sanitize algorithm naming to allow consolidated lookup from the
        cryptography module.
        """

        algo = self.__algo.lower()
        if "aes" in algo:
            # Return generic AES algorithm, key length is determined by the
            # returned algorithm.
            return getattr(ciphers.algorithms, "AES")
        if ("seed" in algo or "sm4" in algo):
            return getattr(ciphers.algorithms, self.__algo.upper())
        if "chacha20" in algo:
            return getattr(ciphers.algorithms, self.__algo)
        if "camellia" in algo:
            return ciphers.algorithms.Camellia
        if (algo in ["des-ede3", "3des"]):
            return ciphers.algorithms.TripleDES

        return ValueError(f"Unknown algorithm for {self.__algo}.")

    @property
    def block_size(self):
        """
        Number of bytes in a block in the associated algorithm.
        """

        try:
            return self.algorithm.block_size // 8
        except AttributeError:
            # Skip AttributeError, that is raised when the given algorithm does
            # not have a block_size attribute. Default to 12.
            pass

        return 12

    @property
    def mode(self):
        """
        Lookup the mode by name. May return None if no mode exists.
        """

        try:
            return getattr(ciphers.modes, self.__mode.upper())
        except AttributeError:
            # Skip AttributeError, that is raised when the given mode cannot be
            # found by name.
            pass

        return None

    @property
    def hash(self):
        """
        Lookup and return the hash by name.
        """

        return getattr(hashes, self.ln.upper())

    def __str__(self):
        return f"{self.ln} ({self.oid})"


class Options:
    """
    Class representing command line options given to this program.
    """

    info = False
    input = None
    output = None
    key = None

    def __init__(self, name):
        parser = argparse.ArgumentParser(prog=name, usage=HELP_TEXT,
                                         add_help=False)
        parser.add_argument("-h", "--help", action="store_true", default=False,
                            help="Print this help text and exit.")
        parser.add_argument("-f", "--file", type=argparse.FileType('rb'),
                            default=sys.stdin.buffer,
                            help="File to read. (Default: stdin)")
        parser.add_argument("-i", "--info", action="store_true", default=False,
                            help="Show information about file.")
        parser.add_argument("-k", "--key", type=argparse.FileType('r'),
                            help="Private key to decrypt file.")
        parser.add_argument("-w", "--write", type=argparse.FileType('wb'),
                            default=sys.stdout.buffer,
                            help="File to write contents. (Default: stdout)")
        parser.add_argument("--warn", action="store_true", default=False,
                            help=(("Warn if message integrity verification "
                                   "fails, instead of erroring out.")))

        args = parser.parse_args()

        # If requested, print help and exit.
        if args.help:
            print_help_and_exit()

        self.key = args.key
        self.info = args.info
        self.input = args.file
        self.output = args.write
        self.warn = args.warn

    def __enter__(self):
        return self

    def __exit__(self, *args):
        # Close all relevant open file handles.
        if self.input:
            self.input.close()
        if self.output:
            self.output.close()
        if self.key:
            self.key.close()


class FileFlags(Flag):
    """
    Flags representing various options of a file encryption, e.g. encryption
    version, message integrity, etc.
    """

    HMAC_INTEGRITY = 1 << 0
    AEAD_INTEGRITY = 1 << 1
    NO_INTEGRITY = 1 << 2
    VERSION_1_ENCRYPTION = 1 << 3
    SAME_CIPHER_FOR_KEY_AND_DATA = 1 << 4

    def expand(self):
        """
        Return human-readable strings for the appropriate flags that are set.
        """

        out = []
        if self & self.SAME_CIPHER_FOR_KEY_AND_DATA:
            out.append("Same cipher for key and data")
        if self & self.HMAC_INTEGRITY:
            out.append("HMAC integrity")
        if self & self.AEAD_INTEGRITY:
            out.append("AEAD integrity")
        if self & self.NO_INTEGRITY:
            out.append("No integrity")
        return ', '.join(out)


class Key:
    """
    Object containing all necessary information regarding a key to decrypt a
    file with.
    """

    __public_digest = None

    __oids = {
        "ec_public_key": ObjectIdentifier("1.2.840.10045.2.1")
    }

    data = None
    private = None
    public = None
    curve_name = ""

    def __init__(self, file, password=None):
        if file:
            self.data = file.read().encode()
            self.private = serialization.load_pem_private_key(self.data,
                                                              password)
            self.public = self.private.public_key()

            self.curve_name = ""
            if isinstance(self.private, ec.EllipticCurvePrivateKey):
                self.curve_name = self.private.curve.name
            elif isinstance(self.private, x25519.X25519PrivateKey):
                self.curve_name = "curve25519"

    @property
    def digest(self):
        """
        Calculate and set the public key digest from the registered key.
        The computation is done at most once. Afterwards the proper value is
        set and returned on demand.
        """

        if self.public and (not self.__public_digest):
            if isinstance(self.private, ec.EllipticCurvePrivateKey):
                curve = self.public.curve.name
                oid = getattr(ec.EllipticCurveOID, curve.upper()).dotted_string
                seq = self.public.public_bytes(
                        encoding=serialization.Encoding.X962,
                        format=serialization.PublicFormat.CompressedPoint)
                enc = asn1.Encoder()
                enc.start()
                with enc.construct(asn1.Numbers.Sequence):
                    with enc.construct(asn1.Numbers.Sequence):
                        enc.write(self.__oids["ec_public_key"].dotted_string,
                                  asn1.Numbers.ObjectIdentifier)
                        enc.write(oid, asn1.Numbers.ObjectIdentifier)
                    enc.write(seq, asn1.Numbers.BitString)
                b = enc.output()
            elif (isinstance(self.private, (x25519.X25519PrivateKey,
                                            rsa.RSAPrivateKey))):
                b = self.public.public_bytes(
                        encoding=serialization.Encoding.DER,
                        format=serialization.PublicFormat.SubjectPublicKeyInfo)
            else:
                raise DecryptionError(("Key digest error: Unknown private key "
                                       "type"))

            h = hashes.Hash(hashes.SHA256())
            h.update(b)
            digest = h.finalize()
            self.__public_digest = digest.hex()
        return self.__public_digest

    @property
    def curve(self):
        """
        Return the curve of this private key.
        Only available for EllipticCurve private keys.
        """
        return self.private.curve

    def exchange(self, *args, **kwargs):
        """
        Perform a key exchange on this private key.
        """
        return self.private.exchange(*args, **kwargs)


class File:
    """
    Class containing all necessary information regarding a file to decrypt.

    Make sure to load the file, decrypt it and only then print the information.
    """

    # This class is the container to contain all file-specific attributes. As
    # these are quite numerous ignore the relevant pylint warning.
    # pylint: disable=too-many-instance-attributes

    __magic_header = b'CRYPTED\x03\x07'
    __tag_len = 16
    # Generate maximum amount of PBKDF2HMAC key derivative. The actual amount
    # used will vary by the according algorithm.
    __max_kdflen = 64

    # Private data for internal usage.
    _options = None
    _key = None
    _matching_key = None
    _hdr_offset = 0
    _bytes_read = 0

    # Fields.
    cipher = None
    decrypted_payload = None
    digest = None
    flags = FileFlags(0)
    hdr = b''
    hdr_len = 0
    kdlen = 0
    key_derivate_len = 0
    key_derivative = b''
    keys = []
    mac_key = b''
    nkeys = 0
    payload = b''
    rounds = 0
    secret = b''
    sym_aad = b''
    sym_iv = b''
    sym_key = b''
    sym_tag = b''
    temp_iv = b''
    temp_key = b''
    temp_aad = b''
    temp_tag = b''

    def __init__(self, options, key):
        self._options = options
        self._key = key

        self.input = options.input
        self.output = options.output

        if self.input.read(len(self.__magic_header)) != self.__magic_header:
            raise DecryptionError(("File was not encrypted with dovecot. "
                                   "Exiting."))

        self.version = struct.unpack('>B', self.input.read(1))[0]

        # Currently only version 1 and 2 files are supported.
        if self.version not in [1, 2]:
            raise DecryptionError(f"Unsupported version {self.version}")

        # To verify header length already register the magic header and the
        # version byte. The rest is counted for dynamically for the reported
        # fields/keys/etc.
        self._bytes_read = len(self.__magic_header) + 1

    @property
    def matching_key(self):
        """
        Find and set the matching key from the registered ones.
        The computation is done at most once. Afterwards the proper value is
        set and returned on demand.
        """

        if not self._matching_key:
            if not self._key.digest:
                return False

            for key in self.keys:
                if key['digest'].hex() == self._key.digest:
                    self._matching_key = key
                    break
        return self._matching_key

    def read_oid(self):
        """
        Read the OID ensuring to properly account for the header offset.
        """

        dec = asn1.Decoder()
        dec.start(self.hdr[self._hdr_offset:])
        _, obj = dec.read()
        self._hdr_offset = self._hdr_offset + dec.m_stack[-1][0]
        self._bytes_read += dec.m_stack[-1][0]
        return ASN1Object(obj)

    def read_bytes(self, count):
        """
        Read bytes ensuring to properly account for the header offset.
        """

        assert (count <= (len(self.hdr) - self._hdr_offset))
        data = self.hdr[self._hdr_offset:self._hdr_offset + count]
        self._hdr_offset = self._hdr_offset + count
        self._bytes_read += count
        return data

    def print(self):
        """
        Gather all available data according to the given output flags and print
        them to the appropriate destination (file/output).
        """

        # The output message is constructed dynamically depending on the
        # combinations of the file's data and key attribute. As this requires
        # relatively many if-conditions, disable the appropriate pylint
        # message.
        # pylint: disable=too-many-branches

        # Print decrypted Payload.
        if self.decrypted_payload:
            self.output.write(self.decrypted_payload)
            self.output.flush()

        # Gather file information for printing.
        out = []
        out.append(format_line("Version", self.version))
        if self.flags:
            out.append(format_line("Flags", self.flags.expand()))

        out.extend([
            format_line("Header length", self.hdr_len),
            format_line("Cipher algo", self.cipher),
            format_line("Digest algo", self.digest),
        ])

        if self.matching_key:
            if len(out) > 0:
                out.append("")

            if self.version == 1:
                enc_key = self.matching_key['encryption_key'].hex()
                out.extend([
                    "Encryption key decryption",
                    format_line("Secret", self.secret.hex(), level=2),
                    format_line("Encryption", enc_key, level=2),
                    format_line("Key", self.temp_key.hex(), level=2),
                    format_line("IV", self.temp_iv.hex(), level=2),
                    "",
                    "Decryption",
                    format_line("Key", self.sym_key.hex(), level=2),
                    format_line("IV", self.sym_iv.hex(), level=2)
                ])
            elif self.rounds > 0:
                out.extend([
                    "Key derivation",
                    format_line("Rounds", self.rounds, level=2),
                ])

                if self.matching_key:
                    out.extend([
                        format_line("Secret", self.secret.hex(), level=2),
                        format_line("Salt",
                                    self.matching_key['peer_key'].hex(),
                                    level=2),
                    ])

                    if self.matching_key['type'] == "EC":
                        enc_key = self.matching_key['encryption_key'].hex()
                        out.extend([
                            "",
                            "Encryption key decryption",
                            format_line("Encryption", enc_key, level=2),
                            format_line("Key", self.temp_key.hex(), level=2),
                            format_line("IV", self.temp_iv.hex(), level=2),
                        ])

                    out.extend([
                        "",
                        "Decryption",
                        format_line("Key", self.sym_key.hex(), level=2),
                        format_line("IV", self.sym_iv.hex(), level=2),
                    ])

                    if FileFlags.HMAC_INTEGRITY in self.flags:
                        out.append(format_line("HMAC", self.sym_aad.hex(),
                                               level=2))
                    elif FileFlags.AEAD_INTEGRITY in self.flags:
                        out.extend([
                            format_line("AAD", self.sym_aad.hex(), level=2),
                            format_line("TAG", self.sym_tag.hex(), level=2),
                        ])
            else:
                out.append("None of the keys match the key provided")

        if self._key.digest:
            out.append(format_line("Provided key", self._key.digest))

        # Provide keys inside the file.
        if len(self.keys) > 0:
            suffix = 's' if len(self.keys) > 1 else ''
            out.extend([
                "",
                f"Key{suffix} (total: {len(self.keys)})",
            ])
            for key in self.keys:
                key_curve = (f" ({self._key.curve_name})" if
                             key['type'] == "EC" else "")
                kt = f"{key['type']}{key_curve}"
                out.extend([
                    format_line("Key type", kt, level=2),
                    format_line("Key digest", key['digest'].hex(), level=2),
                    format_line("Peer key", key['peer_key'].hex(), level=2),
                    format_line("Encrypted", key['encryption_key'].hex(),
                                level=2),
                    format_line("Kd hash", key['data_digest'].hex(), level=2),
                ])

        # Actually print the data.
        if self._options.info and len(out) > 0:
            print('\n'.join(out), file=sys.stderr)

    def decrypt_data(self, *, data, key, iv, aad, tag):
        """
        Decrypt the given data with the appropriate key, iv and additional data
        depending on the registered cipher and its attributes.
        """

        assert self.cipher

        if self.cipher.is_chacha:
            cipher = aead.ChaCha20Poly1305(key)
            return cipher.decrypt(iv, data + tag, aad)

        cipher = ciphers.Cipher(self.cipher.algorithm(key),
                                self.cipher.mode(iv))
        decryptor = cipher.decryptor()

        if isinstance(decryptor, ciphers.AEADCipherContext):
            decryptor.authenticate_additional_data(aad)
            return decryptor.update(data) + decryptor.finalize_with_tag(tag)

        data = decryptor.update(data) + decryptor.finalize()
        if self.cipher.mode == ciphers.modes.CBC:
            pad = padding.PKCS7(cipher.algorithm.block_size)
            unpadder = pad.unpadder()
            data = unpadder.update(data) + unpadder.finalize()

        return data

    def get_derivative_blocks(self, derivative):
        """
        Determine the key, initialization vector and additional data from the
        derivative given.
        """

        assert self.cipher

        blocks = {}

        keysize = self.cipher.keysize
        ivsize = len(derivative) - keysize - self.__tag_len

        if self.cipher.mode in [ciphers.modes.CBC, ciphers.modes.OFB]:
            ivsize = 16
        elif (FileFlags.AEAD_INTEGRITY in self.flags or self.cipher.is_chacha):
            ivsize = 12
        else:
            ivsize = keysize

        start = 0
        end = keysize
        blocks['key'] = derivative[start:end]
        start = end
        end += ivsize
        blocks['iv'] = derivative[start:end]
        start = end
        end += self.__tag_len
        blocks['aad'] = derivative[start:end]

        return blocks

    def decipher_secret(self, derivative):
        """
        Version 2 files can optionally use the same cipher for key and data.
        Use this to decipher the key derivative from PBKDF2HMAC. Fall back to
        AES + CBC for the default cipher.
        """

        assert self.matching_key

        if FileFlags.SAME_CIPHER_FOR_KEY_AND_DATA in self.flags:
            blocks = self.get_derivative_blocks(derivative)
            self.temp_key = blocks['key']
            self.temp_iv = blocks['iv']
            self.temp_aad = blocks['aad']
            if FileFlags.HMAC_INTEGRITY in self.flags:
                self.temp_tag = (
                        self.matching_key['encryption_key'][:self.__tag_len])
                encryption_key = self.matching_key['encryption_key']
            else:
                self.temp_tag = (
                        self.matching_key['encryption_key'][-self.__tag_len:])
                encryption_key = (
                    self.matching_key['encryption_key'][:-self.__tag_len])

            return self.decrypt_data(data=encryption_key,
                                     key=self.temp_key, iv=self.temp_iv,
                                     aad=self.temp_aad, tag=self.temp_tag)

        self.temp_key = derivative[:32]
        self.temp_iv = derivative[32:48]
        unpadder = None

        # Default decipher algorithm + mode = AES + CBC.
        cipher = ciphers.Cipher(ciphers.algorithms.AES(self.temp_key),
                                ciphers.modes.CBC(self.temp_iv))
        unpadder = padding.PKCS7(cipher.algorithm.block_size).unpadder()
        decryptor = cipher.decryptor()

        data = (decryptor.update(self.matching_key['encryption_key']) +
                decryptor.finalize())
        if unpadder:
            data = (unpadder.update(data) + unpadder.finalize())

        return data

    def read_header(self):
        """
        Read message header.

        Version 1:
            Cipher/Digest algorithms are hardcoded. Only one key is contained
            in the header.
        Version 2:
            Version 2 headers contain all necessary file flags, cipher/digest
            algorithms as well as keys and can thusly be determined this way.
        """

        if self.version == 1:
            # AES256-CTR does not have a valid OID.
            self.cipher = "aes-256-ctr"
            # SHA256:
            self.digest = ASN1Object("2.16.840.1.101.3.4.2.1")
            self.hdr_len = struct.unpack('>H', self.input.read(2))[0] + 12
            self.hdr = self.input.read(self.hdr_len - 12)
            self._bytes_read = 12

            # v1 files only have one key.
            key = {"type": "EC"}

            self.rounds = 1
            bytes_to_read = struct.unpack('>H', self.read_bytes(2))[0]
            key['peer_key'] = self.read_bytes(bytes_to_read)
            bytes_to_read = struct.unpack('>H', self.read_bytes(2))[0]
            key['digest'] = self.read_bytes(bytes_to_read)
            bytes_to_read = struct.unpack('>H', self.read_bytes(2))[0]
            key['data_digest'] = self.read_bytes(bytes_to_read)
            bytes_to_read = struct.unpack('>H', self.read_bytes(2))[0]
            key['encryption_key'] = self.read_bytes(bytes_to_read)

            check = struct.unpack('>H', self.read_bytes(2))[0]
            if check != 0:
                raise DecryptionError(("Decryption warning: header format "
                                       f"mismatch (read={check}, expected=0)"))

            self.keys.append(key)
            self._matching_key = key
        elif self.version == 2:
            # Read the relevant fields from the data.
            flags, self.hdr_len = struct.unpack('>II', self.input.read(8))
            self._bytes_read += 8
            self.hdr = self.input.read(self.hdr_len - 18)
            self._hdr_offset = 0
            self.flags = FileFlags(flags)
            self.cipher = self.read_oid()
            self.digest = self.read_oid()
            self.rounds, self.kdlen, self.nkeys = struct.unpack(
                    '>IIB', self.read_bytes(9))

            # Store indicated number of keys from the input.
            for _ in range(self.nkeys):
                key = {}
                t, key['digest'] = struct.unpack('>B32s', self.read_bytes(33))
                if t == 1:
                    key['type'] = "RSA"
                elif t == 2:
                    key['type'] = "EC"
                else:
                    raise DecryptionError(f"Invalid key type {t}")

                bytes_to_read = struct.unpack('>I', self.read_bytes(4))[0]
                key['peer_key'] = self.read_bytes(bytes_to_read)
                bytes_to_read = struct.unpack('>I', self.read_bytes(4))[0]
                key['encryption_key'] = self.read_bytes(bytes_to_read)
                bytes_to_read = struct.unpack('>I', self.read_bytes(4))[0]
                key['data_digest'] = self.read_bytes(bytes_to_read)

                self.keys.append(key)

        # Verify that we are where we think we should be.
        if self._bytes_read != self.hdr_len:
            print(("Decryption warning: header length mismatch "
                   f"(is={self._bytes_read}, expected={self.hdr_len})"),
                  file=sys.stderr)

    def read_data(self):
        """
        Read payload data after the header has been consumed.

        Version 1:
            Rest input data.
        Version 2:
            Split the payload and the message integrity depending on message
            integrity type.
        """

        raw_data = self.input.read()
        if self.version == 1:
            self.payload = raw_data
        elif self.version == 2:
            payload_end = (self.digest.hash.digest_size if
                           FileFlags.HMAC_INTEGRITY in self.flags else
                           self.__tag_len)
            self.payload = raw_data[:len(raw_data) - payload_end]
            self.sym_tag = raw_data[len(raw_data) - payload_end:]

    def determine_encryption_key(self):
        """
        Determine the used encryption key.

        Version 1:
            Only EllipticCurve keys are allowed. Decrypt it using the
            determined digestion algorithm (= SHA256).
        Version 2:
            Additionally to EllipticCurve also RSA keys are allowed. From these
            the appropriate key, initialization vector and additional data is
            determined.
        """
        assert self.matching_key

        if self.version == 1:
            # Read peer key, for v1 only EC allowed.
            if isinstance(self._key.private, x25519.X25519PrivateKey):
                peer = x25519.X25519PublicKey.from_public_bytes(
                        self.matching_key['peer_key'])
                self.secret = self._key.exchange(peer)
            elif isinstance(self._key.private, ec.EllipticCurvePrivateKey):
                peer = ec.EllipticCurvePublicKey.from_encoded_point(
                        self._key.curve, self.matching_key['peer_key'])
                self.secret = self._key.exchange(ec.ECDH(), peer)
            elif self._key.private == None:
                return
            else:
                raise DecryptionError(("Incorrect private key type for v1 "
                                       f"files: {type(self._key.private)}"))

            # Decrypt encryption key.
            hash_obj = hashes.Hash(self.digest.hash())
            hash_obj.update(self.secret)
            self.temp_key = hash_obj.finalize()
            self.temp_iv = b'\x00' * self.__tag_len
            cipher = ciphers.Cipher(ciphers.algorithms.AES256(self.temp_key),
                                    ciphers.modes.CTR(self.temp_iv))
            decryptor = cipher.decryptor()
            enc_key = self.matching_key['encryption_key']
            self.sym_key = (decryptor.update(enc_key) + decryptor.finalize())

            hash_obj = hashes.Hash(self.digest.hash())
            hash_obj.update(self.sym_key)
            hash_val = hash_obj.finalize()
            if hash_val != self.matching_key['data_digest']:
                raise DecryptionError(
                        ("Incorrect encryption key decipher:\n"
                         f"  Calculated: {hash_val.hex()}\n"
                         "  Received:   "
                         f"{self.matching_key['data_digest'].hex()}"))
        elif self.version == 2:
            # Determine key secret.
            if self.matching_key['type'] == "RSA":
                pad = asymmetric_padding.OAEP(
                        mgf=asymmetric_padding.MGF1(algorithm=hashes.SHA1()),
                        algorithm=hashes.SHA1(),
                        label=None)
                self.secret = self._key.private.decrypt(
                        self.matching_key['encryption_key'], pad)
                self.key_derivative = self.secret
            elif self.matching_key['type'] == "EC":
                if isinstance(self._key.private, x25519.X25519PrivateKey):
                    peer = x25519.X25519PublicKey.from_public_bytes(
                            self.matching_key['peer_key'])
                    self.secret = self._key.exchange(peer)
                else:
                    peer = ec.EllipticCurvePublicKey.from_encoded_point(
                            self._key.curve, self.matching_key['peer_key'])
                    self.secret = self._key.exchange(ec.ECDH(), peer)

                # Decipher encryption key.
                kdf = pbkdf2.PBKDF2HMAC(algorithm=self.digest.hash(),
                                        length=self.__max_kdflen,
                                        salt=self.matching_key['peer_key'],
                                        iterations=self.rounds)

                self.key_derivative = self.decipher_secret(
                        kdf.derive(self.secret))

            blocks = self.get_derivative_blocks(self.key_derivative)
            self.sym_key = blocks['key']
            self.sym_iv = blocks['iv']
            self.sym_aad = blocks['aad']

    def decrypt_payload(self):
        """
        Decrypt the already read payload.

        Version 1:
            Hardcoded initialization vector, as well as algorithm + mode.
        Version 2:
            Use the appropriate encryption cipher.
        """

        if self.version == 1:
            if self._key.private == None:
                return

            self.sym_iv = b'\x00' * self.__tag_len
            cipher = ciphers.Cipher(ciphers.algorithms.AES256(self.sym_key),
                                    ciphers.modes.CTR(self.sym_iv))
            decryptor = cipher.decryptor()
            self.decrypted_payload = (decryptor.update(self.payload) +
                                      decryptor.finalize())
        elif self.version == 2:
            self.decrypted_payload = self.decrypt_data(data=self.payload,
                                                       key=self.sym_key,
                                                       iv=self.sym_iv,
                                                       aad=self.sym_aad,
                                                       tag=self.sym_tag)

    def verify_message_integrity(self):
        """
        Verify message integrity of the already read and decrypted payload.

        Version 1:
            No integrity available.
        Version 2:
            Either HMAC or AEAD integrity available.
        """

        if self.version == 1:
            pass
        elif self.version == 2:
            assert self.matching_key

            if FileFlags.HMAC_INTEGRITY in self.flags:
                h = hmac.HMAC(self.sym_aad, self.digest.hash())
                h.update(self.payload)
                h.verify(self.sym_tag)
            elif FileFlags.AEAD_INTEGRITY in self.flags:
                hash_obj = hashes.Hash(self.digest.hash())
                hash_obj.update(self.key_derivative)
                hash_value = hash_obj.finalize()
                hash_rounds = self.rounds
                for i in range(1, hash_rounds + 1):
                    tmp_hash = hashes.Hash(self.digest.hash())
                    tmp_hash.update(hash_value)
                    tmp_hash.update(struct.pack('>I', i))
                    hash_value = tmp_hash.finalize()

                if hash_value != self.matching_key['data_digest']:
                    dd = self.matching_key['data_digest']
                    msg = ("Incorrect message integrity\n"
                           f"{format_line('Calculated', hash_value.hex())}\n"
                           f"{format_line('Received', dd.hex())}")
                    if self._options.warn:
                        print(msg, file=sys.stderr)
                    else:
                        raise DecryptionError(msg)

    def decrypt(self):
        """
        The main entrypoint of the File decryption. Each block is encapsulated
        into its own method.
        """

        self.read_header()
        self.read_data()

        if not self.matching_key:
            print("No matching key found")
            return

        self.determine_encryption_key()
        self.decrypt_payload()
        self.verify_message_integrity()


def main():
    """
    Main entrypoint of this program.
    Parse command line arguments and operate on them, run with -h/--help to get
    all available options.
    """

    with Options(TOOL_NAME) as options:
        if not options.key and not options.info:
            print_help_and_exit(status_code=2,
                                msg=(f"{TOOL_NAME}: error: Either -k/--key or "
                                     "-i/--info is necessary for this script "
                                     "to work.\n"))

        key = Key(options.key)
        file = File(options, key)
        file.decrypt()
        file.print()


if __name__ == '__main__':
    main()
