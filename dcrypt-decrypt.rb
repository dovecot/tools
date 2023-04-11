#!/usr/bin/env ruby

require 'openssl'
require 'optparse'

def read_oid(stream)
  ## read length
  tmp = stream.read(2)
  if tmp[1].ord & 0x80 != 0
    # read bit more
    tmp = "#{tmp}#{stream.read(1)}"
    len = ((tmp[1] & 0x7f) << 8) + tmp[2].ord
  else
    len = tmp[1].ord
  end
  tmp = "#{tmp}#{stream.read len}".force_encoding("binary")
  OpenSSL::ASN1.decode(tmp)
end

def get_pubid_priv(key)
  pub = key.public_key
  grp = key.group
  seq = OpenSSL::ASN1::Sequence.new([
         OpenSSL::ASN1::Sequence.new([
           OpenSSL::ASN1::ObjectId.new('id-ecPublicKey'),
           OpenSSL::ASN1.decode(key.group.to_der),
         ]),
         OpenSSL::ASN1::BitString.new(pub.to_bn(conversion_form = :compressed).to_s(2))
       ])
  OpenSSL::Digest::SHA256.new.digest(seq.to_der.force_encoding("binary"))
end

options = {input: STDIN, output: STDOUT}

op = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} -k key -i -f file -w file"

  opts.on("-i","--info", "Show information about file") do |i|
    options[:info] = i
  end

  opts.on("-k","--key KEY", "Private key to decrypt file") do |k|
    options[:key] = OpenSSL::PKey.read(File.open(k))
    options[:key_digest] = get_pubid_priv(options[:key])
  end

  opts.on("-f", "--file FILE", "File to read instead of stdin") do |f|
    options[:input] = File.open(f,"rb")
  end

  opts.on("-w","--write FILE", "File to write contents instead of stdout") do |w|
    options[:output] = File.open(w,"wb")
  end

  opts.on("-h","--help", "Show help") do |h|
    puts opts
    exit 0
  end

end.parse(ARGV)

unless options[:key] or options[:info]
  exit 0
end

file = {}

## check if we understand this file
unless options[:input].read(9) == "CRYPTED\x03\a"
  raise "Not encrypted with dovecot"
end

options[:input].set_encoding("binary")

## read file version
file[:version] = options[:input].read(1).unpack('C').shift

if file[:version] == 2

  ## read flags
  file[:flags] = options[:input].read(4).unpack('I>').shift

  file[:flags_expanded] = []
  file[:flags_expanded] << "HMAC integrity" if (file[:flags] & 0x01) == 0x01
  file[:flags_expanded] << "AEAD integrity" if (file[:flags] & 0x02) == 0x02
  file[:flags_expanded] << "No integrity" if (file[:flags] & 0x04) == 0x04
  file[:flags_expanded] = file[:flags_expanded].join " ,"

  ## read header length and specs
  file[:hdr_len] = options[:input].read(4).unpack('I>').shift

  file[:cipher] = read_oid(options[:input])
  file[:digest] = read_oid(options[:input])

  (file[:rounds], file[:kdlen], nkeys) = options[:input].read(9).unpack('I>I>C')

  ## read all keys
  file[:keys] = []
  our_key = nil
  tlen = 0
  while(nkeys>0) do
     nkeys = nkeys - 1
     key = {}

     ## Unpack key type and key digest
     (key[:type],key[:digest]) = options[:input].read(33).unpack('Ca*')

     if key[:type] == 1
       key[:type] = "RSA"
     elsif key[:type] == 2
       key[:type] = "EC"
     end

     tlen = tlen + 33
     ## read length and data
     len = options[:input].read(4).unpack('I>').shift
     tlen = tlen + len
     key[:peer_key] = options[:input].read(len)
     len = options[:input].read(4).unpack('I>').shift
     tlen = tlen + len
     key[:encrypted] = options[:input].read(len).force_encoding("binary")
     len = options[:input].read(4).unpack('I>').shift
     tlen = tlen + len
     key[:data_digest] = options[:input].read(len)

     our_key = key if key[:digest] == options[:key_digest]

     file[:keys] << key
  end

  if options[:input].tell != file[:hdr_len]
     our_key = nil
     print "Error: header length mismatch"
  end

  unless our_key == nil
     # decrypt data!

     grp = options[:key].group
     grp.point_conversion_form = :compressed
     our_key[:ephemeral] = OpenSSL::PKey::EC::Point.new(grp, OpenSSL::BN.new(our_key[:peer_key], 2))

     file[:secret] = options[:key].dh_compute_key(our_key[:ephemeral])

     dk_a = OpenSSL::PKCS5.pbkdf2_hmac(file[:secret], key[:peer_key], file[:rounds], 32+16, OpenSSL::Digest.new(file[:digest].ln))
     cipher = OpenSSL::Cipher.new("AES-256-CBC")

     cipher.decrypt
     cipher.key = dk_a[0,32]
     cipher.iv = dk_a[32,16]

     dk_b = cipher.update key[:encrypted]
     dk_b.force_encoding("binary")
     dk_b = "#{dk_b}#{cipher.final}"
     dk_b.force_encoding("binary")

     file[:temp_key] = dk_a[0,32]
     file[:temp_iv] = dk_a[32,16]

     hash = OpenSSL::Digest.new(file[:digest].ln).digest(dk_b)

     (1..2048).each do |i|
       d = OpenSSL::Digest.new(file[:digest].ln)
       d << hash
       d << [i].pack('I>')
       hash = d.digest
     end

     if hash != our_key[:data_digest]
       puts "Decryption error (did not decipher encryption key correctly)"
     end

     # now we have keying data
     file[:sym_key] = dk_b[0,32]
     file[:sym_iv] = dk_b[32,12]
     file[:sym_aad] = dk_b[44,16]

     # see if we can decrypt it
     cipher = OpenSSL::Cipher.new(file[:cipher].ln)
     cipher.decrypt

     cipher.key = file[:sym_key]
     cipher.iv = file[:sym_iv]

     # read data
     data = options[:input].read

     if options[:input].eof?
       file[:sym_tag] = data[data.length-16, 16]
       #cipher.auth_tag = file[:sym_tag]
       data = data[0,data.length-16]
       file[:data_size] = data.size
     end

     cipher.auth_data = file[:sym_aad]
     options[:output].print cipher.update data
     begin
       options[:output].print cipher.final
     rescue
     end
  end

  if options[:info]
    STDERR.puts(<<EOF
Version       : #{file[:version]}
Flags         : #{file[:flags_expanded]}
Header length : #{file[:hdr_len]}
Cipher algo   : #{file[:cipher].ln} (#{file[:cipher].oid})
Digest algo   : #{file[:digest].ln} (#{file[:digest].oid})

Key derivation
  - Rounds    : #{file[:rounds]}
EOF
)
  end

  if our_key
    STDERR.puts(<<EOF
  - Secret    : #{file[:secret].unpack('H*').shift}
  - Salt      : #{our_key[:peer_key].unpack('H*').shift}

Encryption key decryption:
  - Encrypted : #{our_key[:encrypted].unpack('H*').shift}
  - Key       : #{file[:temp_key].unpack('H*').shift}
  - IV        : #{file[:temp_iv].unpack('H*').shift}

Decryption
  - Key       : #{file[:sym_key].unpack('H*').shift}
  - IV        : #{file[:sym_iv].unpack('H*').shift}
EOF
)
    if (file[:flags] & 0x02) == 0x02
      STDERR.puts "  - AAD       : #{file[:sym_aad].unpack('H*').shift}"
      STDERR.puts "  - TAG       : #{file[:sym_tag].unpack('H*').shift}"
    end
  elsif options[:key_digest] then
    STDERR.puts "\nNone of the keys match the key provided\n"
  end

  if options[:key_digest] then
    STDERR.puts "Provided key : #{options[:key_digest].unpack('H*').shift}\n"
  end

  STDERR.puts "\nKey(s) (total: #{file[:keys].count})\n"
  file[:keys].each do |key|
     STDERR.puts(<<EOF
  - Key type  : #{key[:type]}
  - Key digest: #{key[:digest].unpack('H*').shift}
  - Peer key  : #{key[:peer_key].unpack('H*').shift}
  - Encrypted : #{key[:encrypted].unpack('H*').shift}
  - Kd hash   : #{key[:data_digest].unpack('H*').shift}
EOF
)
  end
elsif file[:version] == 1
  # total header length
  file[:hdr_len] = options[:input].read(2).unpack('S>').shift + 12
  key = {}

  ## Read peer key
  len = options[:input].read(2).unpack('S>').shift
  key[:peer_key] = options[:input].read(len)
  if options[:key]
    grp = options[:key].group
    grp.point_conversion_form = :compressed
    key[:ephemeral] = OpenSSL::PKey::EC::Point.new(grp, OpenSSL::BN.new(key[:peer_key], 2))
  end

  ## Read public key ID
  len = options[:input].read(2).unpack('S>').shift
  key[:digest] = options[:input].read(len)

  ## Read encryption key hash
  len = options[:input].read(2).unpack('S>').shift
  key[:data_digest] = options[:input].read(len)

  ## Read encrypted encryption key
  len = options[:input].read(2).unpack('S>').shift
  key[:encrypted] = options[:input].read(len)
  file[:keys] = [key]

  ## This should be 0
  if options[:input].read(2).unpack('S>').shift != 0
    STDERR.puts "Decryption warning: header format mismatch"
  end

  ## See if header is consumed
  if options[:input].tell != file[:hdr_len]
    p options[:input].tell
    p file[:hdr_len]
    STDERR.puts "Decryption warning: header length mismatch"
  end

  # assume it's right key because it's hard to do in ruby
  if options[:key]
    file[:secret] = options[:key].dh_compute_key(key[:ephemeral])
    file[:temp_key] = OpenSSL::Digest::SHA256.digest(file[:secret])

    ## Decrypt encryption key
    cipher = OpenSSL::Cipher.new("AES-256-CTR")
    cipher.decrypt
    cipher.key = file[:temp_key]
    cipher.iv = "\x0" * 16
    file[:sym_key] = cipher.update key[:encrypted]
    file[:sym_key] = "#{file[:sym_key]}#{cipher.final}"

    ## Check it's correct
    if key[:data_digest] != OpenSSL::Digest::SHA256.digest(file[:sym_key])
      raise "Decryption error: invalid decryption key"
    end

    ## Decrypt file
    cipher = OpenSSL::Cipher.new("AES-256-CTR")
    cipher.decrypt
    cipher.key = file[:sym_key]
    cipher.iv = "\x0" * 16

    options[:output].print cipher.update options[:input].read
    options[:output].print cipher.final
  end

  if options[:info]
    STDERR.puts(<<EOF
Version       : #{file[:version]}
Header length : #{file[:hdr_len]}
Cipher algo   : aes-256-ctr
Digest algo   : sha256

EOF
)
  end

  if options[:key]
    STDERR.puts(<<EOF
Encryption key decryption:
  - Secret    : #{file[:secret].unpack('H*').shift}
  - Encrypted : #{key[:encrypted].unpack('H*').shift}
  - Key       : #{file[:temp_key].unpack('H*').shift}
  - IV        : 00000000000000000000000000000000

Decryption
  - Key       : #{file[:sym_key].unpack('H*').shift}
  - IV        : 00000000000000000000000000000000
EOF
)
  end

  STDERR.puts "\nKey(s) (total: #{file[:keys].count})\n"
  file[:keys].each do |key|
     STDERR.puts(<<EOF
  - Key type  : EC
  - Key digest: #{key[:digest].unpack('H*').shift}
  - Peer key  : #{key[:peer_key].unpack('H*').shift}
  - Encrypted : #{key[:encrypted].unpack('H*').shift}
  - Kd hash   : #{key[:data_digest].unpack('H*').shift}
EOF
)
  end
else
  raise "Unsupported version #{file[:version]}"
end
