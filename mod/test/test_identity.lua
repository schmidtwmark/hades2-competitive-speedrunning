local T = require('test.lib')
local Identity = T.load('identity.lua')

T.case('identity: a SteamID64 from its two 32-bit words, exactly', function()
	T.eq(Identity.u64_decimal(0x01100001, 0x000056BA), '76561197960287930')
	T.eq(Identity.u64_decimal(0x01100001, 0xFFFFFFFF), '76561202255233023')
	T.eq(Identity.u64_decimal(0, 0), '0')
	T.eq(Identity.u64_decimal(0xFFFFFFFF, 0xFFFFFFFF), '18446744073709551615')
end)

T.case('identity: the Epic launcher command line gives the account id and name', function()
	local id, name = Identity.parse_epic('"C:\\Games\\Hades II\\Ship\\Hades2.exe" -AUTH_LOGIN=unused -AUTH_PASSWORD=abc '
		.. '-AUTH_TYPE=exchangecode -epicapp=Fig -epicenv=Prod -EpicPortal -epicusername="Mel Inoe" '
		.. '-epicuserid=0123456789ABCDEF0123456789abcdef -epiclocale=en-US')
	T.eq(id, '0123456789abcdef0123456789abcdef')
	T.eq(name, 'Mel Inoe')
	T.eq(select(2, Identity.parse_epic('x -epicusername=Zag -epicuserid=ab12')), 'Zag')
	T.eq(Identity.parse_epic('Hades2.exe /DirectLoadShell=false'), nil, 'a Steam launch')
end)

T.case('identity: names lose markup and control characters and stop at 24 characters', function()
	T.eq(Identity.clean_name('  Mark  '), 'Mark')
	T.eq(Identity.clean_name('{#Bold}Me@lino\n'), '#BoldMelino')
	T.eq(Identity.clean_name(string.rep('a', 30)), string.rep('a', 24))
	T.eq(Identity.clean_name(string.rep('é', 30)), string.rep('é', 24), 'whole UTF-8 characters')
	T.eq(Identity.clean_name(''), nil)
	T.eq(Identity.clean_name(nil), nil)
end)
