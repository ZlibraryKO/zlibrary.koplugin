-- This file can be used to override Z-library credentials.
-- Remove the leading '--' from the lines you want to use and fill in your details.
-- Any values set here will take precedence over the settings configured in the UI.
--
-- userId and userKey are a ready-made session, for when signing in does not work at all: sign in
-- to Z-library in a browser and copy its remix_userid and remix_userkey cookies here. Set both or
-- neither. The plugin then never has to reach a login endpoint, and these sessions do not expire.

return {
    -- baseUrl = "https://your.zlibrary.domain.com",
    -- email = "your_email",
    -- password = "your_password",
    -- userId = "your_remix_userid",
    -- userKey = "your_remix_userkey",
}
