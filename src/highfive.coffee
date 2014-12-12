# Description:
#   Reward awesomeness with public recognition and (maybe) dollars.
#
# Commands:
#   hubot highfive @<user> for <awesome thing> - makes a loud announcement in a public chatroom
#   hubot highfive @<user> $<amount> for <awesome thing> - makes a loud announcement and sends the user an Amazon.com giftcard
#   hubot highfive config - show URL for configuration UI
#
# Configuration:
#   HUBOT_HIGHFIVE_EMAIL_SERVICE - Service for looking up email addresses by user names (defaults to 'slack')
#   HUBOT_SLACK_API_TOKEN - If using the 'slack' email service, this is your API token. Get one from https://api.slack.com/tokens
#   HUBOT_HIGHFIVE_ROOM - Room for making noise when someone is high-fived. Defaults to the room the request was made in
#   HUBOT_HIGHFIVE_AWARD_LIMIT - upper limit for giftcard awards. Set to 0 to disable giftcards. Default is 150.

Path = require 'path'
fs = require 'fs'
coffee = require 'coffee-script'

debug = ->
if process.env.HUBOT_HIGHFIVE_DEBUG?
    debug = (msg, txt) -> msg.send "DEBUG " + txt

module.exports = (robot) ->
    # Services for getting emails from users
    email_fetchers =
        slack: (username1, username2, callback) ->
            # Slack decorates some usernames
            [username1,username2] = (u.replace(/^[<@]*|[>]$/gm, '') for u in [username1, username2])
            new SlackApp(robot).listUsers (resp) ->
                grabber = (name) ->
                    (x for x in resp.members when name in [x.name, x.id])[0]?.profile.email
                return callback(null, null) unless resp.members?
                [e1, e2] = (grabber(u) for u in [username1, username2])
                callback e1, e2
        dummy: (username1, username2, callback) ->
            # This is for testing.
            [e1, e2] = (robot.brain.userForName(u)?.email for u in [username1, username2])
            callback e1, e2

    email_fetcher = email_fetchers[process.env.HUBOT_HIGHFIVE_EMAIL_SERVICE || 'slack']

    # Config UI serving
    configpath = Path.join __dirname, '..', 'config'
    robot.router.get '/highfive/', (req, res) ->
        res.set 'Content-Type', 'text/html'
        res.sendfile Path.join configpath, 'config.html'
    robot.router.get '/highfive/config.css', (req, res) ->
        res.set 'Content-Type', 'text/css'
        res.sendfile Path.join configpath, 'config.css'
    robot.router.get '/highfive/gridforms.js', (req, res) ->
        res.set 'Content-Type', 'application/x-javascript'
        res.sendfile Path.join configpath, 'gridforms.js'
    robot.router.get '/highfive/config.js', (req, res) ->
        res.set 'Content-Type', 'application/x-javascript'
        cs = fs.readFileSync Path.join(configpath, 'config.coffee'), 'utf-8'
        js = coffee.compile cs
        res.send js
    robot.router.get '/highfive/values.json', (req, res) ->
        res.set 'Content-Type', 'application/x-javascript'
        data = {}
        envvars = [
            'HUBOT_HIGHFIVE_EMAIL_SERVICE',
            'HUBOT_HIGHFIVE_ROOM',
            'HUBOT_HIGHFIVE_AWARD_LIMIT',
            'HUBOT_TANGOCARD_ROOTURL'
            'HUBOT_TANGOCARD_USER',
            'HUBOT_TANGOCARD_KEY',
            'HUBOT_TANGOCARD_CC',
            'HUBOT_TANGOCARD_AUTH',
            'HUBOT_TANGOCARD_CUSTOMER',
            'HUBOT_TANGOCARD_ACCOUNT',
            'HUBOT_TANGOCARD_EMAIL',
        ]
        for v in envvars
            data[v] = process.env[v] || ''
        res.send JSON.stringify data

    # Ask for the config UI
    robot.respond /highfive config/, (msg) ->
        hostname = process.env.HUBOT_HOSTNAME || 'http://localhost:8080'
        msg.reply "#{hostname}/highfive/"

    # Debug echo helper
    if process.env.HUBOT_HIGHFIVE_DEBUG?
        robot.hear /.*/, (msg) ->
            msg.send """
            ```
            #{JSON.stringify msg, null, 2}
            ```
            """

    # The main responder
    robot.respond /highfive (.+?)( \$(\d+))? for (.*)/, (msg) ->
        from_user = msg.message.user.name
        to_user = msg.match[1][1..]
        amt = parseInt(msg.match[3] or 0)
        reason = msg.match[4]
        debug msg, "from `#{from_user}` to `#{to_user}` amount `#{amt}` reason `#{reason}`"

        email_fetcher from_user, to_user, (from_email, to_email) ->
            debug msg, "from #{from_email} to #{to_email}"
            # Safety checks:
            # - Don't target a nonexistent user
            # - Don't target yourself
            # - $150 or less
            # - Any others?
            unless to_email
                return msg.reply "Who's #{msg.match[1]}?"
            if to_email == from_email
                return msg.reply "High-fiving yourself is just clapping."
            if amt > (process.env.HUBOT_HIGHFIVE_AWARD_LIMIT || 150)
                return msg.reply "$#{amt} is more like a high-500. Think smaller."

            # TODO: send to a configurable channel
            # TODO: fix channel mention (fetch ID on startup? service?)
            # TODO: fix user mentions
            msg.send """
            #{msg.random GIFs}
            @channel WOOOOOO! #{from_user} is high-fiving #{to_user} for #{reason}!
            """


            if amt > 0 and process.env.HUBOT_HIGHFIVE_AWARD_LIMIT != 0
                tango = new TangoApp(robot)
                cust = process.env.HUBOT_TANGOCARD_CUSTOMER
                acct = process.env.HUBOT_TANGOCARD_ACCOUNT

                tango.getAccountStatus cust, acct, (resp) ->
                    debug msg, "account status `#{JSON.stringify resp}`"

                    unless resp.success
                        return msg.send "(Problem getting Tango Card status: '#{resp.error_message}'. You might want 'highfive config'.)"
                    return sendCard() if resp.account.available_balance/100 >= amt

                    # Insufficient balance, attempt to fund the account
                    amtToFund = (process.env.HUBOT_HIGHFIVE_AWARD_LIMIT || 150) * 2 * 100 # in cents
                    cc = process.env.HUBOT_TANGOCARD_CC
                    auth = process.env.HUBOT_TANGOCARD_AUTH
                    robot.http('http://jsonip.com').get() (err, res, body) ->
                        jsonip = JSON.parse body

                        tango.fundAccount cust, acct, amtToFund, jsonip.ip, cc, auth, (resp) ->
                            debug msg, "funding response `#{JSON.stringify resp}`"
                            unless resp.success
                                return msg.send "(Problem funding Tango Card account: '#{resp.denial_message}'. You might want 'highfive config'.)"
                            return sendCard() if resp.success

                sendCard = ->
                    message = "High five for #{reason}!"
                    tango.orderAmazonDotComCard cust, acct, 'High-five', amt*100, from_user, 'High Five!', to_user, to_email, message, (resp) ->
                        debug msg, "order response `#{JSON.stringify resp}`"
                        unless resp.success
                            errmsg = resp.invalid_inputs_message || resp.error_message || resp.denial_message
                            return msg.send "(Problem ordering gift card: '#{errmsg}'. You might want 'highfive config'.)"
                        msg.send "A $#{amt} gift card is on its way!"
                        # TODO: log to spreadsheet

        , (e1, e2) -> # error callback from email_fetcher
            console.log "ERROR '#{e1}' '#{e2}'"
            msg.reply "Who's #{msg.match[1]}?" unless e1

class BaseApiApp
    constructor: (@robot, @baseurl, @opts) ->

    requester: (endpoint) ->
        @robot.http("#{@baseurl}#{endpoint}").headers(@opts).query(@opts)

    get: (endpoint, callback) ->
        @requester(endpoint).get() (err, res, body) ->
            try
                json = JSON.parse body
            catch error
                console.log "API error: #{err}"
            callback json

    post: (endpoint, data, callback) ->
        data = JSON.stringify data
        @requester(endpoint).post(data) (err, res, body) ->
            try
                json = JSON.parse body
            catch error
                console.log "API error: #{err}"
            callback json

# Slack API helper class
class SlackApp extends BaseApiApp
    constructor: (robot) ->
        super robot, 'https://slack.com/api/',
            token: process.env.HUBOT_SLACK_API_TOKEN

    listUsers: (callback) ->
        @get 'users.list', callback

    getUser: (uid, callback) ->
        @get "users.info?user=#{uid}", callback

# Tango Card API helper class
class TangoApp extends BaseApiApp
    constructor: (robot) ->
        user = process.env.HUBOT_TANGOCARD_USER
        pass = process.env.HUBOT_TANGOCARD_KEY
        auth = "Basic " + new Buffer("#{user}:#{pass}").toString('base64')
        super robot, process.env.HUBOT_TANGOCARD_ROOTURL || 'https://api.tangocard.com/raas/v1/',
            Authorization: auth

    getAccountStatus: (cust, acct, callback) ->
        @get "accounts/#{cust}/#{acct}", callback

    fundAccount: (cust, acct, amt, ip, cc, auth, callback) ->
        @post 'cc_fund',
            customer: cust
            account_identifier: acct
            amount: amt
            client_ip: ip
            cc_token: cc
            security_code: auth
        , callback

    orderAmazonDotComCard: (cust, acct, campaign, amt, from, subject, to, email, message, callback) ->
        data =
            customer: cust
            account_identifier: acct
            campaign: campaign
            recipient:
                name: to
                email: email
            sku: "AMZN-E-V-STD"
            amount: amt
            reward_from: from
            reward_subject: subject
            reward_message: message
            send_reward: true
        @post 'orders', data, callback


# GIFs for celebration
GIFs = [
    'http://i.giphy.com/zl170rmVMCpEY.gif',
    'http://i.giphy.com/yoJC2vEwxkwbMZmSCk.gif',
    'http://i.giphy.com/Qh5dZDCFqr1dK.gif',
    'http://i.giphy.com/GCLlQnV7wzKLu.gif',
    'http://i.giphy.com/MhHXeM4SpKrpC.gif',
    'http://i.giphy.com/Z7bxVQl7nWes.gif',
    'http://i.giphy.com/ns8SCo6O6g7nO.gif',
    'http://a.fod4.com/images/GifGuide/dancing/280sw007883.gif',
    'http://a.fod4.com/images/GifGuide/dancing/pr2.gif',
    'http://0.media.collegehumor.cvcdn.com/46/28/291cb0abc0c99142aace1353dc12b755-car-race-high-five.gif',
    'http://2.media.collegehumor.cvcdn.com/75/26/b31d5b98a4a27537d075960b7b247773-giant-high-five-from-jackass.gif',
    'http://2.media.collegehumor.cvcdn.com/84/67/ff88c44dec5f9c2747e30549a375d481-bear-high-five.gif',
    'http://0.media.collegehumor.cvcdn.com/17/53/30709bc3c9b060baf771c0b2e2626f95-snow-white-high-five.gif',
    'http://i.giphy.com/p3LmvxiO6noGc.gif',
    'http://i.giphy.com/DYvroxifyHEmA.gif',
    'http://i.giphy.com/kolvlRnXh8Jj2.gif',
    'http://i.giphy.com/tX5iDEX1n1Xxe.gif',
    'http://i.giphy.com/xeXEpUVvAxCV2.gif',
    'http://i.giphy.com/UkhHIZ37IDRGo.gif',
    'http://i.giphy.com/oUZqX2UgK2xnq.gif',
    'http://a.fod4.com/images/GifGuide/dancing/163563561.gif',
    'http://i.giphy.com/mEOjrcTumos80.gif',
    'http://i.giphy.com/99dauSQPLUuIg.gif',
    'http://i.giphy.com/3HICMfLGqgWRy.gif',
    'http://i.giphy.com/GYU7rBEQtBGfe.gif',
    'http://i.giphy.com/vXEeRBP3QeJ2w.gif',
    'http://i.giphy.com/Cj3Ce7e8h2EKY.gif',
    'http://i.giphy.com/3Xtt7hlXvUTvi.gif',
    'http://i.giphy.com/1453cgfKvRLMyc.gif',
    'http://i.giphy.com/WdxAL8nmOCQ5a.gif',
    'http://a.fod4.com/images/GifGuide/dancing/tumblr_llatbbCeky1qbnthu.gif',
    'http://i.giphy.com/FrDlVZMD96nzG.gif',
]
