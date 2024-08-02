-- Copyright 2023 Open-Xchange Software Gmbh
--
-- See COPYING for details on license and warranty.
--
-- https://doc.dovecot.org/2.4/howto/lua_director.html
--
-- IMPORTANT! Remember to change the database credentials before using this
--

local crc32 = require 'crc32'
local bit = require 'bit32'
local DBI = require 'DBI'
local dbd = nil
local math = require 'math'

local lookup_stmt = nil
local update_stmt = nil
local lookup_backend_stmt = nil
local lookup_backends_stmt = nil

local extra_attributes = nil

function auth_passdb_init(args)
  local err
  dbd, err = DBI.Connect('MySQL', 'dovecot', 'dovecot', 'dovecot')
  assert(dbd, err)
  dbd:autocommit(true)

  lookup_stmt, err = dbd:prepare('SELECT backends.id AS bid FROM backends JOIN user_backend ON ' ..
                                 'backends.id = user_backend.backend_id WHERE user_backend.user_hash = ?')
  assert(lookup_stmt, err)
  update_stmt, err = dbd:prepare('INSERT INTO user_backend (backend_id, user_hash) VALUES(?, ?)')
  assert(update_stmt, err)
  lookup_backend_stmt, err = dbd:prepare('SELECT * FROM backends WHERE id = ?')
  assert(lookup_backend_stmt, err)
  lookup_backends_stmt, err = dbd:prepare('SELECT backends.id FROM backends WHERE state = 0')
  assert(lookup_backends_stmt, err)

  extra_attributes = args
end

function auth_passdb_lookup(req)
  local h = crc32.crc32(120254, req.user)
  h = bit.bxor(bit.lshift(bit.band(h, 0xffff0000), 16), bit.band(h, 0x0000ffff))
  req:log_debug("hash "..req.user.." => "..tostring(h))

  -- perform lookup
  local success, err = lookup_stmt:execute(h)
  assert(success, err)
  local bid = nil

  for row in lookup_stmt:rows(true) do
    bid = row['bid']
  end

  if bid == nil then
    req:log_debug("no mapping for "..tostring(h))
    success, err = lookup_backends_stmt:execute()
    assert(success, err)
    local bids = {}
    for row in lookup_backends_stmt:rows(true) do
     table.insert(bids, row['id'])
    end
    assert(#bids > 0, "No backends configured in database")
    bid = bids[math.random(1, #bids)]
    req:log_debug("mapping "..tostring(h).." to "..tostring(bid))
    success, err = update_stmt:execute(bid, h)
    if not success then
      req:log_debug("map update for "..req.user.." failed: " .. err)
      req:log_debug("trying to lookup again, maybe it was race condition?")
      success, err = lookup_stmt:execute(h)
      assert(success, err)
      for row in lookup_stmt:rows(true) do
        bid = row['bid']
      end
    end
  end

  assert(bid, "No backend got assigned")

  req:log_debug(tostring(h).." has backend "..tostring(bid))

  success, err = lookup_backend_stmt:execute(bid)
  assert(success, err)

  local backend_host = nil
  local backend_ip = nil

  for row in lookup_backend_stmt:rows(true) do
    backend_host = row['hostname']
    backend_ip = row['hostip']
  end

  local result = extra_attributes
  result["proxy"] = "y"
  result["host"] = backend_host

  if backend_ip ~= nil and backend_ip ~= "" then
    result["hostip"] = backend_ip
  end

  return dovecot.auth.PASSDB_RESULT_OK, result
end
