#!/usr/bin/env lua

-- Copyright (c) 2013-2015, CZ.NIC, z.s.p.o. (http://www.nic.cz/)
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--    * Redistributions of source code must retain the above copyright
--      notice, this list of conditions and the following disclaimer.
--    * Redistributions in binary form must reproduce the above copyright
--      notice, this list of conditions and the following disclaimer in the
--      documentation and/or other materials provided with the distribution.
--    * Neither the name of the CZ.NIC nor the
--      names of its contributors may be used to endorse or promote products
--      derived from this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL CZ.NIC BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--
-- This file is interpreted as a lua script.
-- It applies firewall rules issued by CZ.NIC s.z.p.o.
-- as a part of Turris project (see https://www.turris.cz/)
--
-- To enable/disable the rules please edit /etc/config/firewall
--
-- config include
--   option path /usr/share/firewall/turris
--
-- It is periodically executed using cron (see /etc/cron.d/fw-rules - within firewall reload)
--
-- Related UCI config /etc/config/firewall-turris
--

--TODO
-- tests (loaded ipsets, loaded NFLOG, ...)
-- Create iptables rules if needed
-- Handle ulogd
-- use overrides
-- debug mode
--TODO

local io = require 'io'
local nixio = require 'nixio'
local os = require 'os'
local uci = require 'uci'
local ip = require 'luci.ip'
local util = require 'luci.util'

local VERSION = "0"
local LOCK_FILE_PATH = "/tmp/turris-firewall-rules.lock"
local IPSET_TMP = "/tmp/turris-ipsets"
local IPSET_TMP_LOAD = IPSET_TMP .. ".to_load"
local lock_file = nil
local ipset_lists = {}
local config = {
	ipset_path = "/usr/share/firewall/turris-ipsets.gz",
	pcap = {
		enabled = false,
		extensive = false,
		log_dropped = false,
		log_other_dropped = false
	},
	overrides = {
	}
}

-- set logging
nixio.openlog("turris-firewall-rules")

function log(level, message)
	nixio.syslog(level, '(v' .. VERSION .. ') ' .. message)
end

function lock()
	lock_file = nixio.open(LOCK_FILE_PATH, "w")
	if not lock_file:lock("tlock") then
		log('err', "An instance of turris-firewall-rules is already running!")
		os.exit(1)
	end
end

function unlock()
	if lock_file then
		nixio.fs.unlink(LOCK_FILE_PATH)
		lock_file:close()
	end
end

function unlock_and_exit(code)
	unlock()
	os.exit(code)
end

function read_uci()
	local function read_bool(text)
		if text == "1" or text == "yes" or text == "on" or text == "true" or text == "enabled" then
			return true
		elseif text == "0" or text == "no" or text == "off" or text == "false" or text == "disabled" then
			return false
		else
			return nil
		end
	end

	local cursor = uci.cursor()

	-- read wans from uci
	local wan = cursor:get("nikola", "main", "wan_ifname")
	if wan then
		config.wan = wan[1]
	end
	local wan6 = cursor:get("nikola", "main", "wan6_ifname")
	if wan6 then
		config.wan6 = wan6[1]
	end

	-- read pcap
	local pcap_enabled = cursor:get("firewall-turris", "pcap", "enabled")
	if pcap_enabled ~= nil then
		config.pcap.enabled = pcap_enabled
	end
	local pcap_extensive = cursor:get("firewall-turris", "pcap", "extensive")
	if pcap_extensive ~= nil then
		config.pcap.extensive = pcap_extensive
	end
	local pcap_dropped = cursor:get("firewall-turris", "pcap", "log_dropped")
	if pcap_dropped ~= nil then
		config.pcap.log_dropped = pcap_dropped
	end
	local pcap_other_dropped = cursor:get("firewall-turris", "pcap", "log_other_dropped")
	if pcap_other_dropped ~= nil then
		config.pcap.log_other_dropped = pcap_other_dropped
	end

	-- read overrides
	cursor:foreach("firewall-turris", "rule_override", function(record)
		local name = nil
		if record.rule_id then
			name = record.rule_id
		elseif string.sub(record[".name"], 1, 3) ~= "cfg" then
			name = record[".name"]
		else
			log('warning', "uci override invalid!")
			return
		end
		config.overrides[name] = {}
		for key, value in pairs(record) do
			if key == "action" then
				config.overrides[name].action = value
			elseif key == "pcap_enabled" then
				config.overrides[name].enabled = read_bool(value)
			elseif key == "pcap_extensive" then
				config.overrides[name].extensive = read_bool(value)
			elseif key == "pcap_log_dropped" then
				config.overrides[name].log_dropped = read_bool(value)
			end
		end
	end)
end

function detect_wans()
	local ipv4_wans = {}
	local routes4 = ip.routes({family = 4})
	for _, record in pairs(routes4) do
		if tostring(record.dest) == "0.0.0.0/0" then
			table.insert(ipv4_wans, record.dev)
		end
	end

	local ipv6_wans = {}
	local routes6 = ip.routes({family = 6})
	-- sort ipv6 records according to metric
	table.sort(routes6, function(a, b) return tonumber(a.metric, 16) < tonumber(b.metric, 16) end)
	for _, record in pairs(routes6) do
		if tostring(record.dest) == "::/0" then
			table.insert(ipv6_wans, record.dev)
		end
	end

	-- return first records only
	return ipv4_wans[1], ipv6_wans[1]
end

function load_ipsets()
	local function insert_ipset(full_name, skip)
		local splitted = util.split(full_name, '_')
		table.insert(ipset_lists, {
			full_name = full_name,
			rule_id = splitted[2],
			action = splitted[3],
			address_port = splitted[4],
			family = splitted[5],
			skip = skip
		})
	end
	if 0 ~= os.execute('gunzip -c "' .. config.ipset_path .. '" > "' .. IPSET_TMP .. '"') then
		log("err", "Failed to unpack ipset rules")
		os.remove(IPSET_TMP)
		unlock_and_exit(1)
	end
	local f_src, err = io.open(IPSET_TMP)
	if not f_src then
		log("err", err)
		os.remove(IPSET_TMP)
		unlock_and_exit(1)
	end
	local f_dst, err = io.open(IPSET_TMP_LOAD, "w")
	if not f_dst then
		log("err", err)
		os.remove(IPSET_TMP)
		unlock_and_exit(1)
	end

	local loaded_ipsets = {}
	for name in io.popen("ipset list -n | grep '^turris' | cut -d ' ' -f2"):lines() do
		loaded_ipsets[name] = true
	end

	-- read ipsets
	for line in f_src:lines() do
		-- list header
		if line:match('^create ') then
			local full_name = line:match('turris[^ ]*')
			-- don't insert loaded injected ipsets
			if line:match('^create turris_1') and loaded_ipsets[full_name .. "_X"] then
				insert_ipset(full_name, true)
			else
				insert_ipset(full_name)
				f_dst:write(line .. "\n")
			end
		else
			f_dst:write(line .. "\n")
		end
	end

	-- load ipsets
	if 0 ~= os.execute('ipset restore -f "' .. IPSET_TMP_LOAD .. '"') then
        log( "err", "Failed to restore ipsets")
		os.remove(IPSET_TMP)
		os.remove(IPSET_TMP_LOAD)
		unlock_and_exit(1)
	end

	-- switch ipsets
	for _, ipset in pairs(ipset_lists) do
		if not ipset.skip then
			if loaded_ipsets[ipset.full_name .. '_X'] then
				if 0 ~= os.execute('ipset swap "' .. ipset.full_name .. '" "' .. ipset.full_name .. '_X"') then
					log("warning", "Failed to swap ipset '" .. ipset.full_name .. "'")
				else
					os.execute('ipset destroy "' .. ipset.full_name .. '"')
				end
			else
				if 0 ~= os.execute('ipset rename "' .. ipset.full_name .. '" "' .. ipset.full_name .. '_X"') then
					log("warning", "Failed to rename ipset '" .. ipset.full_name .. "'")
				end
			end
		end
	end

	os.remove(IPSET_TMP)
	os.remove(IPSET_TMP_LOAD)
end

-- locking
lock()

config.wan, config.wan6 = detect_wans()
read_uci()

-- setting overrides using env variables
config.ipset_path = nixio.getenv("OVERRIDE_IPSETS") or config.ipset_path
config.wan = nixio.getenv("OVERRIDE_WAN") or config.wan
config.wan6 = nixio.getenv("OVERRIDE_WAN6") or config.wan6

-- try to fill the other wan as well
config.wan = config.wan or config.wan6
config.wan6 = config.wan6 or config.wan

if nil == config.wan then
	log("err", "Unable to determine the WAN interface. Exiting...")
	unlock_and_exit(1)
else
	log("info", "IPv4 WAN interface used - '" .. config.wan .. "'")
	log("info", "IPv6 WAN interface used - '" .. config.wan6 .. "'")
end

load_ipsets()

-- unlocking
unlock()
