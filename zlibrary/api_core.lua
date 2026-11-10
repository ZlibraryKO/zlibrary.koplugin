-- The Api table every part of the plugin's API layer fills, and the error texts callers match by
-- value (so the match survives translation), with their classifiers.
--
-- zlibrary.api used to be one 2,182-line module. It is now a facade (api.lua) over this core and
-- the parts api_transport, api_login, api_books, api_downloads, api_account and api_mirrors, which
-- all fill this one table; the private helpers several of them need live in api_shared, which is
-- deliberately not on Api. Parts require this module, never the facade, so there is no cycle;
-- callers keep requiring zlibrary.api. The code was moved, not rewritten: diff with --color-moved
-- against the commit before the split to see where it came from.

local T = require("zlibrary.gettext")

local Api = {}

-- Leading text of the name-resolution error built in Api.makeHttpRequest.
-- Ui.showRetryErrorDialog matches on this exact value to offer base URL auto-discovery,
-- so both sides must share the message id for the match to survive translation.
Api.DNS_ERROR_TEXT = T("Could not find the server address")

-- Leading text of the bot-challenge error built in Api.makeHttpRequest, exported for the same
-- reason as DNS_ERROR_TEXT: Ui.showRetryErrorDialog matches on it to offer auto-discovery, and
-- both sides must share the message id for that to survive translation.
Api.BLOCKED_TEXT = T("This Z-library server is refusing automated access")

-- Fallback text for a sign-in the server answered but would not accept. Exported for the same
-- reason as the two above: Zlibrary:_promptForCredentials matches on it to tell "your password is
-- wrong" apart from "we never got an answer", and a match on the English literal would hold in
-- one locale out of fourteen.
Api.CREDENTIALS_REJECTED_TEXT = T("Credentials rejected or invalid response")

-- Did the server read these credentials and refuse them?
--
-- Positive matches only. Anything unrecognised -- a timeout, a dead mirror, a bot-challenge page,
-- an unparseable body, a rate limit -- means no answer arrived, not that the password is wrong.
-- Getting that default backwards would lock a reader out of storing credentials at all whenever
-- their mirror is down, which is the common case for this plugin.
--
-- Separate from isAuthenticationError on purpose: that one drives session re-login on ordinary
-- API calls, and widening it would change retry behaviour across the plugin for no benefit here.
function Api.isCredentialRejection(error_message)
    if not error_message then return false end
    local error_str = tostring(error_message)
    -- Server wording, which arrives untranslated.
    if string.find(error_str, "Incorrect email or password", 1, true) then return true end
    if string.find(error_str, "Please login", 1, true) then return true end
    -- Our own fallback, matched by value so it survives translation.
    if string.find(error_str, Api.CREDENTIALS_REJECTED_TEXT, 1, true) then return true end
    return false
end

-- Is the server asking for fewer requests rather than judging these credentials?
--
-- Z-library answers a run of sign-ins with "Too many logins #2. Try again later." -- on rpc.php as
-- a 200 with an errors[] entry, on /eapi/user/login as a 400, so the wording is the signal and the
-- status is not. It says nothing about whether the password is right, and every further attempt
-- extends the lockout, which is why Api.login stops rather than asking the second endpoint.
function Api.isRateLimited(error_message)
    if not error_message then return false end
    return string.find(tostring(error_message), "Too many logins", 1, true) ~= nil
end

-- Did this mirror answer with a browser check instead of the API?
--
-- Matched by value like the classifiers above, so it survives translation. makeHttpRequest marks
-- the mirror itself, but it usually runs in a forked child, where nothing it writes to the
-- settings file survives (Config.disableSubprocessWrites) -- so a caller that receives such a
-- result in the parent marks it there instead. discovery.lua is the one that matters: its sweep
-- is what reads those marks back.
function Api.isBlockedError(error_message)
    if not error_message then return false end
    return string.find(tostring(error_message), Api.BLOCKED_TEXT, 1, true) ~= nil
end

function Api.isAuthenticationError(error_message)
    if not error_message then
        return false
    end
    
    local error_str = tostring(error_message)

    if string.find(error_str, "Please login", 1, true) ~= nil or
       string.find(error_str, "Incorrect email or password", 1, true) ~= nil then
        return true
    end

    -- A download-limit error is deliberately NOT treated as an authentication error. The session is
    -- valid; the quota is spent. Re-authenticating cannot fix it, and treating it as auth made every
    -- quota hit re-submit the user's credentials and repeat the whole download before finally
    -- reporting the limit.
    return false
end

return Api
