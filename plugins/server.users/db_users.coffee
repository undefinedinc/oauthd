# oauthd
# http://oauth.io
#
# Copyright (c) 2013 thyb, bump
# For private use only.

async = require 'async'
Mailer = require '../../lib/mailer'

{config,check,db} = shared = require '../shared'

# register a new user
exports.register = check mail:check.format.mail, pass:/^.{6,}$/, (data, callback) ->
	date_inscr = (new Date).getTime()
	return callback new check.Error 'You need to give your name.' if not data.name

	db.redis.hget 'u:mails', data.mail, (err, iduser) ->
		return callback err if err
		return callback new check.Error 'This email already exists' if iduser
		db.redis.incr 'u:i', (err, val) ->
			return callback err if err
			prefix = 'u:' + val + ':'
			key = db.generateUid()

			dynsalt = Math.floor(Math.random() * 9999999)
			pass = db.generateHash data.pass + dynsalt

			arr = ['mset', prefix+'mail', data.mail,
				prefix+'key', key,
				prefix+'validated', 0,
				prefix+'pass', pass,
				prefix+'salt', dynsalt
				prefix+'date_inscr', date_inscr,
				prefix+'name', data.name ]

			if data.company
				arr.push prefix + 'company'
				arr.push data.company

			db.redis.multi([
				arr,
				[ 'hset', 'u:mails', data.mail, val ]
			]).exec (err, res) ->
				return callback err if err
				user = id:val, mail:data.mail, name: data.name, company: data.company, date_inscr:date_inscr, key:key
				shared.emit 'user.register', user
				return callback null, user

exports.cancelUpdateEmail = (req, callback) ->
	user_id = req.user.id
	prefix = "u:#{user_id}:"
	db.redis.mset [ prefix + 'mail_changed', ''], (err, res) =>
		return callback null, {cancelled: true}

exports.updateEmail = (req, callback) ->
	email = req.body.email
	user_id = req.user.id
	prefix = "u:#{user_id}:"
	old_email = null

	db.redis.mget [ prefix + 'mail'], (err, res) =>
		old_email = res[0]

		db.redis.hget 'u:mails', email, (err, id) ->
			return callback err if err
			return callback new check.Error "Your email has not changed" if old_email == email
			return callback new check.Error "#{email} already exists" if id

			validation_key = db.generateUid()
			db.redis.mset [
				prefix + 'mail_changed', email,
				prefix + 'key', validation_key
			], (err) ->
				return callback err if err

				#send mail with key
				options =
					to:
						email: email
					from:
						name: 'OAuth.io'
						email: 'team@oauth.io'
					subject: 'OAuth.io - You email address has been updated'
					body: "Hello,\n\n
In order to validate your new email address, please click the following link: https://" + config.url.host + "/validate/" + user_id + "/" + validation_key + "\n

--\n
OAuth.io Team"
				mailer = new Mailer options
				mailer.send (err, result) ->
					return callback err if err
					user = id:user_id, mail:email
					return callback null, user

# update user infos
exports.updateAccount = (req, callback) ->
	data = req.body.profile
	user_id = req.user.id
	prefix = "u:#{user_id}:"

	db.redis.mset [
		prefix + 'name', data.name,
		prefix + 'location', data.location,
		prefix + 'company', data.company,
		prefix + 'website', data.website
	], (err) ->
		return callback err if err
		user = id:user_id, name:data.name, company:data.company, website:data.website, location:data.location
		return callback null, user


exports.isValidable = (data, callback) ->
	key = data.key
	iduser = data.id
	prefix = 'u:' + iduser + ':'
	db.redis.mget [prefix+'mail', prefix+'key', prefix+'validated', prefix+'pass', prefix+'mail_changed'], (err, replies) ->
		user =
			mail: replies[0]
			key: replies[1]
			validated: replies[2]
			pass: replies[3]
			mail_changed: replies[4]

		return callback err if err
		# return callback null, is_validable: false if user.pass? and not user.mail_changed? or not user.pass? and user.mail_changed?
		return callback null, is_validable: false if user.key != key

		if user.mail_changed # change email
			return callback null, is_validable: false if user.mail_changed.length == 0
			db.redis.multi([
				[ 'hdel', 'u:mails', replies[0] ],
				[ 'hset', 'u:mails', replies[4], iduser ],
				[ 'mset', prefix+'validated', 1,
					prefix+'mail', replies[4],
					prefix+'mail_changed', '',
					prefix+'validated', '1'
					prefix+'key', '' ]
			]).exec (err, res) ->
				return callback err  if err
				return callback null, is_updated: true, mail: user.mail_changed, id: iduser
		else # validable but no password
			return callback null, is_validable: false if user.validated == '1'
			return callback null, is_validable: true, mail: user.mail, id: iduser

# validate user mail
exports.validate = (data, callback) ->
	dynsalt = Math.floor(Math.random()*9999999)
	pass = db.generateHash data.pass + dynsalt
	exports.isValidable {
		id: data.id,
		key: data.key
	}, (err, res) ->
		return callback new check.Error "This page does not exists." if not res.is_validable or err
		prefix = 'u:' + res.id + ':'
		key = db.generateUid()
		db.redis.mset [
			prefix+'validated', 1,
			prefix+'date_validate', (new Date).getTime()
		], (err) ->
			return err if err
			shared.emit 'user.validate', id: res.id, mail: res.mail, key:key
			return callback null, mail: res.mail, id: res.id

# lost password
exports.lostPassword = check mail:check.format.mail, (data, callback) ->

	mail = data.mail
	db.redis.hget 'u:mails', data.mail, (err, iduser) ->
		return callback err if err
		return callback new check.Error "This email isn't registered" if not iduser
		prefix = 'u:' + iduser + ':'
		db.redis.mget [prefix+'mail', prefix+'key_pass', prefix+'validated'], (err, replies) ->
			return callback new check.Error "This email is not validated yet. Patience... :)" if replies[2] == '0'
			# ok email validated  (contain password)
			key = replies[1]
			if not key
				dynsalt = Math.floor(Math.random() * 9999999)
				key = db.generateHash(dynsalt).replace(/\=/g, '').replace(/\+/g, '').replace(/\//g, '')

				# set new key
				db.redis.mset [
					prefix + 'key_pass', key
				], (err, res) ->
					return err if err

			#send mail with key
			options =
					to:
						email: replies[0]
					from:
						name: 'OAuth.io'
						email: 'team@oauth.io'
					subject: 'OAuth.io - Lost Password'
					body: "Hello,\n\n
Did you forget your password ?\n
To change it, please use the follow link to reset your password.\n\n

#{config.host_url}/resetpassword/#{iduser}/#{key}\n\n

--\n
OAuth.io Team"
				mailer = new Mailer options
				mailer.send (error, result) ->
					return callback error if error
					return callback null

exports.isValidKey = (data, callback) ->
	key = data.key
	iduser = data.id
	prefix = 'u:' + iduser + ':'
	db.redis.mget [prefix + 'mail', prefix + 'key_pass'], (err, replies) ->
		return callback err if err

		if replies[1].replace(/\=/g, '').replace(/\+/g, '') != key
			return callback null, isValidKey: false

		return callback null, isValidKey: true, email: replies[0], id: iduser

exports.resetPassword = check pass:/^.{6,}$/, (data, callback) ->
	exports.isValidKey {
		id: data.id,
		key: data.key
	}, (err, res) ->
		return callback err if err
		return callback new check.Error "This page does not exists." if not res.isValidKey

		prefix = 'u:' + res.id + ':'
		dynsalt = Math.floor(Math.random() * 9999999)
		pass = db.generateHash data.pass + dynsalt

		db.redis.mset [
			prefix + 'pass', pass,
			prefix + 'salt', dynsalt,
			prefix + 'key_pass', '', # clear
			prefix + 'validated', 1
		], (err) ->
			return callback err if err
			return callback null, email:res.email, id:res.id

# change password
exports.updatePassword = (req, callback) ->
	data = req.body
	iduser = req.user.id
	new_pass = data.new_password
	pass = data.current_password
	return callback new check.Error 'Your password must have a least 6 characters' if pass? and pass.length < 6

	prefix = 'u:' + iduser + ':'
	db.redis.mget [
		prefix+'pass',
		prefix+'salt',
		prefix+'mail',
		prefix+'date_inscr',
		prefix+'validated'], (err, replies) ->
			return callback err if err
			calcpass = db.generateHash pass + replies[1]
			return callback new check.Error 'Bad password' if replies[0] != calcpass || replies[4] != "1"

			#set new_pass to prefix_pass / refresh salt
			dynsalt = Math.floor(Math.random() * 9999999)
			pass = db.generateHash new_pass + dynsalt
			db.redis.mset [
				prefix+'pass', pass,
				prefix+'salt', dynsalt
			], (err) ->
				return callback err  if err
				return callback null, updated: true

# get a user by his id
exports.get = check 'int', (iduser, callback) ->
	prefix = 'u:' + iduser + ':'
	db.redis.mget [ prefix + 'mail',
		prefix + 'date_inscr',
		prefix + 'name',
		prefix + 'location',
		prefix + 'company',
		prefix + 'website',
		prefix + 'addr_one',
		prefix + 'addr_second',
		prefix + 'company',
		prefix + 'country_code',
		prefix + 'name',
		prefix + 'phone',
		prefix + 'type',
		prefix + 'zipcode',
		prefix + 'city',
		prefix + 'vat_number',
		prefix + 'use_profile_for_billing',
		prefix + 'state',
		prefix + 'country',
		prefix + 'mail_changed',
		prefix + 'validated' ]
	, (err, replies) ->
		return callback err if err
		profile =
			id:iduser,
			mail:replies[0],
			date_inscr:replies[1],
			name: replies[2],
			location: replies[3],
			company: replies[4],
			website: replies[5],
			addr_one: replies[6],
			addr_second: replies[7],
			company: replies[8],
			country_code: replies[9],
			name: replies[10],
			phone: replies[11],
			type: replies[12],
			zipcode: replies[13],
			city : replies[14],
			vat_number: replies[15],
			use_profile_for_billing: replies[16] == "true" ? true : false
			state : replies[17],
			country : replies[18],
			mail_changed: replies[19]
			validated: replies[20]
		for field of profile
			profile[field] = '' if profile[field] == 'undefined'

		exports.getPlan iduser, (err, plan) ->
			return callback err if err
			return callback null, profile: profile, plan: plan


# delete a user account
exports.remove = check 'int', (iduser, callback) ->
	prefix = 'u:' + iduser + ':'
	db.redis.get prefix+'mail', (err, mail) ->
		return callback err if err
		return callback new check.Error 'Unknown user' unless mail
		exports.getApps iduser, (err, appkeys) ->
			tasks = []
			for key in appkeys
				do (key) ->
					tasks.push (cb) -> db.apps.remove key, cb
			async.series tasks, (err) ->
				return callback err if err

				db.redis.multi([
					[ 'hdel', 'u:mails', mail ]
					[ 'del', prefix+'mail', prefix+'pass', prefix+'salt', prefix+'validated', prefix+'key'
							, prefix+'apps', prefix+'date_inscr' ]
				]).exec (err, replies) ->
					return callback err if err
					shared.emit 'user.remove', mail:mail
					callback()

# get a user by his mail
exports.getByMail = check check.format.mail, (mail, callback) ->
	db.redis.hget 'u:mails', mail, (err, iduser) ->
		return callback err if err
		return callback new check.Error 'Unknown mail' unless iduser
		prefix = 'u:' + iduser + ':'
		db.redis.mget [prefix+'mail', prefix+'date_inscr'], (err, replies) ->
			return callback err if err
			return callback null, id:iduser, mail:replies[0], date_inscr:replies[1]

# get apps ids owned by a user
exports.getApps = check 'int', (iduser, callback) ->
	db.redis.smembers 'u:' + iduser + ':apps', (err, apps) ->
		return callback err if err
		return callback new check.Error 'Unknown mail' if not apps
		return callback null, [] if not apps.length
		keys = ('a:' + app + ':key' for app in apps)
		db.redis.mget keys, (err, appkeys) ->
			return callback err if err
			return callback null, appkeys

exports.getPlan = check 'int', (iduser, callback) ->
	db.redis.get "u:#{iduser}:current_plan", (err, plan_id) =>
		return callback err if err
		return callback null if not plan_id
		plan = db.plans[plan_id]
		plan_id = plan_id.substr 0, plan_id.length - 3  if plan_id.substr(plan_id.length - 2, 2) is 'fr'

		return callback null,
			name:plan_id
			displayName:plan.name
			nbUsers:plan.users
			nbApp:plan.apps
			nbProvider:plan.providers
			responseDelay:plan.support

# is an app owned by a user
exports.hasApp = check 'int', check.format.key, (iduser, key, callback) ->
	db.apps.get key, (err, app) ->
		return callback err if err
		db.redis.sismember 'u:' + iduser + ':apps', app.id, callback

# check if mail & pass match
exports.login = check check.format.mail, 'string', (mail, pass, callback) ->
	db.redis.hget 'u:mails', mail, (err, iduser) ->
		return callback err if err
		return callback new check.Error 'Unknown mail' unless iduser
		prefix = 'u:' + iduser + ':'
		db.redis.mget [
			prefix+'pass',
			prefix+'salt',
			prefix+'mail',
			prefix+'date_inscr',
			prefix+'validated'], (err, replies) ->
				return callback err if err
				calcpass = db.generateHash pass + replies[1]
				return callback new check.Error 'Bad password' if replies[0] != calcpass || replies[4] != "1"
				return callback null, id:iduser, mail:replies[2], date_inscr:replies[3], validated:(replies[4] == "1")

exports.updateProviders = check 'int', (iduser, callback) ->
	exports.getApps iduser, (e, apps) ->
		return callback e if e
		cmds = []
		providers = {}
		for app in apps
			do (app) ->
				cmds.push (callback) ->
					db.apps.getKeysets app, (e, keysets) ->
						#return callback e if e
						return callback() if e # skip crashed apps
						providers[keyset] = true for keyset in keysets
						callback()
		async.parallel cmds, (e,r) ->
			return callback e if e
			pkey = 'u:' + iduser + ':providers'
			providers = Object.keys(providers)
			providers.unshift 'sadd', pkey
			multicmds = [['del', pkey]]
			multicmds.push providers if providers.length > 2
			db.redis.multi(multicmds).exec (e,r) ->
				return callback e if e
				callback null, providers.length

exports.updateConnections = check 'int', ['int','number'], (iduser, date, callback) ->
	setStat = (sum) ->
		db.redis.set "u:#{iduser}:nb_auth:#{year}-#{month+1}", sum, (e, r) ->
			return callback e if e
			shared.emit 'user.update_nbauth', id:iduser, "#{year}-#{month+1}", sum
			callback()

	date = new Date date
	year = date.getFullYear()
	month = date.getMonth()
	exports.getApps iduser, (e, keys) ->
		return callback e if e
		return setStat 0 if not keys or not keys.length
		stkeys = ("st:co:a:#{key}:m:#{year}-#{month+1}" for key in keys)
		db.redis.mget stkeys, (e,stats) ->
			return callback e if e
			sum = 0
			for st in stats
				sum += st-0 if st
			setStat sum

shared.on 'connect.auth', (data) ->
	db.apps.getOwner data.key, (e, user) ->
		return if e
		date = new Date
		year = date.getFullYear()
		month = date.getMonth()
		db.redis.incr "u:#{user.id}:nb_auth:#{year}-#{month+1}", (e, nb) ->
			return if e
			shared.emit 'user.update_nbauth', user, "#{year}-#{month+1}", nb

shared.on 'connect.auth.new_uid', (data) ->
	db.apps.getOwner data.key, (e, user) ->
		return if e
		date = new Date
		year = date.getFullYear()
		month = date.getMonth()
		db.redis.incr "u:#{user.id}:nb_uid:#{year}-#{month+1}", (e, nb) ->
			return if e
			shared.emit 'user.update_nbuid', user, "#{year}-#{month+1}", nb

shared.on 'connect.auth.new_mid', (data) ->
	db.apps.getOwner data.key, (e, user) ->
		return if e
		date = new Date
		year = date.getFullYear()
		month = date.getMonth()
		db.redis.incr "u:#{user.id}:nb_mid:#{year}-#{month+1}", (e, nb) ->
			return if e
			shared.emit 'user.update_nbmid', user, "#{year}-#{month+1}", nb

## Event: add app to user when created
shared.on 'app.create', (req, app) ->
	if req.user?.id
		db.redis.sadd 'u:' + req.user.id + ':apps', app.id
		db.redis.scard 'u:' + req.user.id + ':apps', (e, nbapps) ->
			shared.emit 'user.update_nbapps', req.user, nbapps


## Event: remove app from user when deleted
shared.on 'app.remove', (req, app) ->
	if req.user?.id
		db.redis.srem 'u:' + req.user.id + ':apps', app.id
		db.redis.scard 'u:' + req.user.id + ':apps', (e, nbapps) ->
			shared.emit 'user.update_nbapps', req.user, nbapps

updateProviders_byapp = (data) ->
	db.apps.getOwner data.app, (e, user) ->
		return if e
		exports.updateProviders user.id, (e, nb) ->
			return if e
			shared.emit 'user.update_nbproviders', user, nb


shared.on 'app.remkeyset', updateProviders_byapp
shared.on 'app.addkeyset', updateProviders_byapp