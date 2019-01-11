'use strict'

import canonical from './imports/canonical.coffee'
import { ArrayMembers, ArrayWithLength, NumberInRange, NonEmptyString, IdOrObject, ObjectWith } from './imports/match.coffee'
import { getTag, isStuck, canonicalTags } from './imports/tags.coffee'

# Blackboard -- data model
# Loaded on both the client and the server

# how often we send keep alive presence messages.  increase/decrease to adjust
# client/server load.
PRESENCE_KEEPALIVE_MINUTES = 2

# this is used to yield "zero results" in collections which index by timestamp
NOT_A_TIMESTAMP = -9999

emojify = if Meteor.isServer
  require('../server/imports/emoji.coffee').default
else
  (s) -> s

BBCollection = Object.create(null) # create new object w/o any inherited cruft

# Names is a synthetic collection created by the server which indexes
# the names and ids of RoundGroups, Rounds, and Puzzles:
#   _id: mongodb id (of a element in RoundGroups, Rounds, or Puzzles)
#   type: string ("roundgroups", "rounds", "puzzles")
#   name: string
#   canon: canonicalized version of name, for searching
Names = BBCollection.names = \
  if Meteor.isClient then new Mongo.Collection 'names' else null

# LastAnswer is a synthetic collection created by the server which gives the
# solution time of the most recently-solved puzzle.
#    _id: random UUID
#    solved: solution time
#    type: string ("puzzles", "rounds", or "roundgroups")
#    target: id of most recently solved puzzle/round/round group
LastAnswer = BBCollection.last_answer = \
  if Meteor.isClient then new Mongo.Collection 'last-answer' else null

# RoundGroups are:
#   _id: mongodb id
#   name: string
#   canon: canonicalized version of name, for searching
#   created: timestamp (sort key)
#   created_by: canon of Nick
#   touched: timestamp -- records edits to tag, order, group, etc.
#   touched_by: canon of Nick with last touch
#   solved:  timestamp -- null (not missing or zero) if not solved
#            (actual answer is in a tag w/ name "Answer")
#   solved_by:  timestamp of Nick who confirmed the answer
#   incorrectAnswers: [ { answer: "Wrong", who: "answer submitter",
#                         backsolve: ..., provided: ..., timestamp: ... }, ... ]
#   tags: status: { name: "Status", value: "stuck" }, ...
#   rounds: [ array of round _ids, in order ]
#   (next field is a bit racy, but it's fixed up by the server)
#   round_start: integer, indicating how many rounds total are in all
#                preceding round groups (a bit racy, but server fixes it up)
RoundGroups = BBCollection.roundgroups = new Mongo.Collection "roundgroups"
if Meteor.isServer
  RoundGroups._ensureIndex {canon: 1}, {unique:true, dropDups:true}

# Rounds are:
#   _id: mongodb id
#   name: string
#   canon: canonicalized version of name, for searching
#   created: timestamp
#   created_by: canon of Nick
#   touched: timestamp -- records edits to tag, order, group, etc.
#   touched_by: canon of Nick with last touch
#   solved:  timestamp -- null (not missing or zero) if not solved
#            (actual answer is in a tag w/ name "Answer")
#   solved_by:  timestamp of Nick who confirmed the answer
#   incorrectAnswers: [ { answer: "Wrong", who: "answer submitter",
#                         backsolve: ..., provided: ..., timestamp: ... }, ... ]
#   tags: status: { name: "Status", value: "stuck" }, ... 
#   puzzles: [ array of puzzle _ids, in order ]
#   drive: google drive url or id
Rounds = BBCollection.rounds = new Mongo.Collection "rounds"
if Meteor.isServer
  Rounds._ensureIndex {canon: 1}, {unique:true, dropDups:true}

# Puzzles are:
#   _id: mongodb id
#   name: string
#   canon: canonicalized version of name, for searching
#   created: timestamp
#   created_by: canon of Nick
#   touched: timestamp
#   touched_by: canon of Nick with last touch
#   solved:  timestamp -- null (not missing or zero) if not solved
#            (actual answer is in a tag w/ name "Answer")
#   solved_by:  timestamp of Nick who confirmed the answer
#   incorrectAnswers: [ { answer: "Wrong", who: "answer submitter",
#                         backsolve: ..., provided: ..., timestamp: ... }, ... ]
#   tags: status: { name: "Status", value: "stuck" }, ... 
#   drive: google drive url or id
Puzzles = BBCollection.puzzles = new Mongo.Collection "puzzles"
if Meteor.isServer
  Puzzles._ensureIndex {canon: 1}, {unique:true, dropDups:true}

# CallIns are:
#   _id: mongodb id
#   type: string ("puzzles", "rounds", or "roundgroups")
#   target: _id of Puzzle/Round/RoundGroup
#   answer: string (proposed answer to call in)
#   created: timestamp
#   created_by: canon of Nick
#   submitted_to_hq: true/false
#   backsolve: true/false
#   provided: true/false
CallIns = BBCollection.callins = new Mongo.Collection "callins"
if Meteor.isServer
  CallIns._ensureIndex {created: 1}, {}
  CallIns._ensureIndex {type: 1, target: 1, answer: 1}, {unique:true, dropDups:true}

# Quips are:
#   _id: mongodb id
#   text: string (quip to present at callin)
#   created: timestamp
#   created_by: canon of Nick
#   last_used: timestamp (0 if never used)
#   use_count: integer
Quips = BBCollection.quips = new Mongo.Collection "quips"
if Meteor.isServer
  Quips._ensureIndex {last_used: 1}, {}

# Polls are:
#   _id: mongodb id
#   created: timestamp of creation
#   created_by: userId of creator
#   question: "poll question"
#   options: list of {canon: "canonical text", option: "original text"}
#   votes: document where keys are canonical user names and values are {canon: "canonical text" timestamp: timestamp of vote}
Polls = BBCollection.polls = new Mongo.Collection "polls"

# Users are:
#   _id: canonical nickname
#   located: timestamp
#   located_at: object with numeric lat/lng properties
#   priv_located, priv_located_at: these are the same as the
#     located/located_at properties, but they are updated more frequently.
#     The server throttles the updates from priv_located* to located* to
#     prevent a N^2 blowup as everyone gets updates from everyone else
#   priv_located_order: FIFO queue for location updates
#   nickname (non-canonical form of _id)
#   real_name (optional)
#   gravatar (optional email address for avatar)
#   services: map of provider-specific stuff; hidden on client
if Meteor.isServer
  Meteor.users._ensureIndex {priv_located_order: 1},
    partialFilterExpression:
      priv_located_order: { $exists: true }
  # We don't push the index to the client, so it's okay to have it update
  # frequently.
  Meteor.users._ensureIndex {priv_located_at: '2dsphere'}, {}

# Messages
#   body: string
#   nick: canonicalized string (may match some Nicks.canon ... or not)
#   system: boolean (true for system messages, false for user messages)
#   action: boolean (true for /me commands)
#   oplog:  boolean (true for semi-automatic operation log message)
#   presence: optional string ('join'/'part' for presence-change only)
#   bot_ignore: optional boolean (true for messages from e.g. email or twitter)
#   to:   destination of pm (optional)
#   poll: _id of poll (optional)
#   starred: boolean. Pins this message to the top of the puzzle page or blackboard.
#   room_name: "<type>/<id>", ie "puzzle/1", "round/1".
#                             "general/0" for main chat.
#                             "oplog/0" for the operation log.
#   timestamp: timestamp
#   useful: boolean (true for useful responses from bots; not set for "fun"
#                    bot messages and commands that trigger them.)
#   useless_cmd: boolean (true if this message triggered the bot to
#                         make a not-useful response)
#
# Messages which are part of the operation log have `nick`, `message`,
# and `timestamp` set to describe what was done, when, and by who.
# They have `system=false`, `action=true`, `oplog=true`, `to=null`,
# and `room_name="oplog/0"`.  They also have three additional fields:
# `type` and `id`, which give a mongodb reference to the object
# modified so we can hyperlink to it, and stream, which maps to the
# JS Notification API 'tag' for deduping and selective muting.
Messages = BBCollection.messages = new Mongo.Collection "messages"
OldMessages = BBCollection.oldmessages = new Mongo.Collection "oldmessages"
if Meteor.isServer
  for M in [ Messages, OldMessages ]
    M._ensureIndex {to:1, room_name:1, timestamp:-1}, {}
    M._ensureIndex {nick:1, room_name:1, timestamp:-1}, {}
    M._ensureIndex {room_name:1, timestamp:-1}, {}
    M._ensureIndex {room_name:1, timestamp:1}, {}
    M._ensureIndex {room_name:1, starred: -1, timestamp: 1},
      partialFilterExpression: starred: true
    M._ensureIndex {timestamp: 1}, {}

# Pages -- paging metadata for Messages collection
#   from: timestamp (first page has from==0)
#   to: timestamp
#   room_name: corresponds to room_name in Messages collection.
#   prev: id of previous page for this room_name, or null
#   next: id of next page for this room_name, or null
#   archived: boolean (true iff this page is in oldmessages)
# Messages with from <= timestamp < to are included in a specific page.
Pages = BBCollection.pages = new Mongo.Collection "pages"
if Meteor.isServer
  # used in the observe code in server/batch.coffee
  Pages._ensureIndex {room_name:1, to:-1}, {unique:true}
  # used in the publish method
  Pages._ensureIndex {next: 1, room_name:1}, {}
  # used for archiving
  Pages._ensureIndex {archived:1, next:1, to:1}, {}

# Last read message for a user in a particular chat room
#   nick: canonicalized string, as in Messages
#   room_name: string, as in Messages
#   timestamp: timestamp of last read message
LastRead = BBCollection.lastread = new Mongo.Collection "lastread"
if Meteor.isServer
  LastRead._ensureIndex {nick:1, room_name:1}, {unique:true, dropDups:true}
  LastRead._ensureIndex {nick:1}, {} # be safe

# Chat room presence
#   nick: canonicalized string, as in Messages
#   room_name: string, as in Messages
#   timestamp: timestamp -- when user was last seen in room
#   foreground: boolean (true if user's tab is still in foreground)
#   foreground_uuid: identity of client with tab in foreground
#   present: boolean (true if user is present, false if not)
Presence = BBCollection.presence = new Mongo.Collection "presence"
if Meteor.isServer
  Presence._ensureIndex {nick: 1, room_name:1}, {unique:true, dropDups:true}
  Presence._ensureIndex {timestamp:-1}, {}
  Presence._ensureIndex {present:1, room_name:1}, {}

# this reverses the name given to Mongo.Collection; that is the
# 'type' argument is the name of a server-side Mongo collection.
collection = (type) ->
  if Object::hasOwnProperty.call(BBCollection, type)
    BBCollection[type]
  else
    throw new Meteor.Error(400, "Bad collection type: "+type)

# pretty name for (one of) this collection
pretty_collection = (type) ->
  switch type
    when "oplogs" then "operation log"
    when "roundgroups" then "round group"
    when "oldmessages" then "old message"
    else type.replace(/s$/, '')

drive_id_to_link = (id) ->
  "https://docs.google.com/folder/d/#{id}/edit"
spread_id_to_link = (id) ->
  "https://docs.google.com/spreadsheets/d/#{id}/edit"
doc_id_to_link = (id) ->
  "https://docs.google.com/document/d/#{id}/edit"

(->
  # private helpers, not exported
  unimplemented = -> throw new Meteor.Error(500, "Unimplemented")

  isDuplicateError = (error) ->
    Meteor.isServer and error?.name in ['MongoError', 'BulkWriteError'] and error?.code==11000

  huntPrefix = (type) ->
    # this is a huge hack, it's too hard to find the correct
    # round group to use.  But this helps avoid reloading the hunt software
    # every time the hunt domain changes.
    rg = RoundGroups.findOne({}, sort: ['created'])
    if rg?.link
      return rg.link.replace(/\/+$/, '') + '/' + type + '/'
    else
      return Meteor.settings?[type+'_prefix']

  # a key of BBCollection
  ValidType = Match.Where (x) ->
    check x, NonEmptyString
    Object::hasOwnProperty.call(BBCollection, x)
  # a type of an object that can have an answer
  ValidAnswerType = Match.Where (x) ->
    check x, ValidType
    x == 'puzzles' || x == 'rounds' || x == 'roundgroups'

  oplog = (message, type="", id="", who="", stream="") ->
    Messages.insert
      room_name: 'oplog/0'
      nick: canonical(who)
      timestamp: UTCNow()
      body: message
      bodyIsHtml: false
      type:type
      id:id
      oplog: true
      followup: true
      action: true
      system: false
      to: null
      stream: stream

  newObject = (type, args, extra, options={}) ->
    check args, ObjectWith
      name: NonEmptyString
      who: NonEmptyString
    now = UTCNow()
    object =
      name: args.name
      canon: canonical(args.name) # for lookup
      created: now
      created_by: canonical(args.who)
      touched: now
      touched_by: canonical(args.who)
      tags: canonicalTags(args.tags or [], args.who)
    for own key,value of (extra or Object.create(null))
      object[key] = value
    try
      object._id = collection(type).insert object
    catch error
      if isDuplicateError error
        # duplicate key, fetch the real thing
        return collection(type).findOne({canon:canonical(args.name)})
      throw error # something went wrong, who knows what, pass it on
    unless options.suppressLog
      oplog "Added", type, object._id, args.who, \
          if type in ['puzzles', 'rounds', 'roundgroups'] \
              then 'new-puzzles' else ''
    return object

  renameObject = (type, args, options={}) ->
    check args, ObjectWith
      id: NonEmptyString
      name: NonEmptyString
      who: NonEmptyString
    now = UTCNow()

    # Only perform the rename and oplog if the name is changing
    # XXX: This is racy with updates to findOne().name.
    if collection(type).findOne(args.id).name is args.name
      return false

    try
      collection(type).update args.id, $set:
        name: args.name
        canon: canonical(args.name)
        touched: now
        touched_by: canonical(args.who)
    catch error
      # duplicate name--bail out
      if isDuplicateError error
        return false
      throw error
    unless options.suppressLog
      oplog "Renamed", type, args.id, args.who
    return true

  deleteObject = (type, args, options={}) ->
    check type, ValidType
    check args, ObjectWith
      id: NonEmptyString
      who: NonEmptyString
    name = collection(type)?.findOne(args.id)?.name
    return false unless name
    unless options.suppressLog
      oplog "Deleted "+pretty_collection(type)+" "+name, \
          type, null, args.who
    collection(type).remove(args.id)
    return true

  setTagInternal = (updateDoc, args) ->
    check args, ObjectWith
      name: NonEmptyString
      value: Match.Any
      who: NonEmptyString
      now: Number
    updateDoc.$set ?= {}
    updateDoc.$set["tags.#{canonical(args.name)}"] = 
      name: args.name
      value: args.value
      touched: args.now
      touched_by: canonical(args.who)
    true

  deleteTagInternal = (updateDoc, name) ->
    check name, NonEmptyString
    updateDoc.$unset ?= {}
    updateDoc.$unset["tags.#{canonical(name)}"] = ''
    true

  newDriveFolder = (type, id, name) ->
    check type, NonEmptyString
    check id, NonEmptyString
    check name, NonEmptyString
    return unless Meteor.isServer
    res = share.drive.createPuzzle name
    return unless res?
    collection(type).update id, { $set:
      drive: res.id
      spreadsheet: res.spreadId
      doc: res.docId
    }

  renameDriveFolder = (new_name, drive, spreadsheet, doc) ->
    check new_name, NonEmptyString
    check drive, NonEmptyString
    check spreadsheet, Match.Optional(NonEmptyString)
    check doc, Match.Optional(NonEmptyString)
    return unless Meteor.isServer
    share.drive.renamePuzzle(new_name, drive, spreadsheet, doc)

  deleteDriveFolder = (drive) ->
    check drive, NonEmptyString
    return unless Meteor.isServer
    share.drive.deletePuzzle drive

  parentObject = do ->
    lookup =
      puzzles: (id) -> ['rounds', Rounds.findOne(puzzles: id)]
      rounds: (id) -> ['roundgroups', RoundGroups.findOne(rounds: id)]
      roundgroups: (id) -> [null, null]
    (type, id) -> lookup[type]?(id)

  moveObject = (type, id, direction) ->
    check type, NonEmptyString
    check id, NonEmptyString
    check direction, Match.Where (x) -> x=='up' or x=='down'

    adjSib = (type, id, dir, nonempty=true) ->
      sameLevel = true
      if type is 'roundgroups'
        parentType = parent = null
        sibs = RoundGroups.find({}, sort: ['created']).map (rg)->rg._id
      else
        [parentType, parent] = parentObject(type, id)
        sibs = parent[type]
      pos = sibs.indexOf(id)
      newPos = if dir is 'prev' then (pos-1) else (pos+1)
      if 0 <= newPos < sibs.length
        return [parentType, parent?._id, newPos, sibs[newPos], sameLevel]
      # otherwise, need to go up a level.
      upSibId = parent?._id
      sameLevel = false
      return [parentType, null, 0, null, sameLevel] unless upSibId
      loop
        [upType, upId, upPos, upSibId, _] = adjSib(parentType, upSibId, dir, true)
        return [parentType, null, 0, null, sameLevel] unless upSibId # no more sibs
        # check that this sibling has children (if nonempty is true)
        prevSibs = collection(parentType).findOne(upSibId)[type]
        newPos = if dir is 'prev' then (prevSibs.length - 1) else 0
        if 0 <= newPos < prevSibs.length
          return [parentType, upSibId, newPos, prevSibs[newPos], sameLevel]
        if prevSibs.length==0 and not nonempty
          return [parentType, upSibId, 0, null, sameLevel]
        # crap, adjacent parent has no children, need *next* parent (loop)

    dir = if direction is 'up' then 'prev' else 'next'
    [parentType,newParent,newPos,adjId,sameLevel] = adjSib(type,id,dir,false)
    args = if (direction is 'up') is sameLevel then {before:adjId} else {after:adjId}
    # now do the move.  note that there are races, in that we're not guaranteed
    # some other concurrent re-ordering/insertions haven't made this the
    # 'wrong' place to insert --- but we *are* going to insert it *somewhere*
    # regardless.  Hopefully the user will notice and forgive us if the
    # object ends up slightly out of place.
    switch type
      when 'puzzles'
        return false unless newParent # can't go further in this direction
        [args.puzzle, args.round] = [id, newParent]
        Meteor.call 'addPuzzleToRound', args
      when 'rounds'
        return false unless newParent # can't go further in this direction
        [args.round, args.group] = [id, newParent]
        Meteor.call 'addRoundToGroup', args
      when 'roundgroups'
        return false unless adjId # can't go further in this direction
        # this is a bit of a hack!
        thisGroup = RoundGroups.findOne(id)
        thatGroup = RoundGroups.findOne(adjId)
        # swap creation times! (i told you this was a hack)
        [thisCreated,thatCreated] = [thisGroup.created, thatGroup.created]
        RoundGroups.update thisGroup._id, $set: created: thatCreated
        RoundGroups.update thatGroup._id, $set: created: thisCreated
        return true # it's a hack and we know it, clap your hands
      else
        throw new Meteor.Error(400, "bad type: #{type}")

  Meteor.methods
    newRoundGroup: (args) ->
      check @userId, NonEmptyString
      newObject "roundgroups", {args..., who: @userId},
        incorrectAnswers: []
        solved: null
        solved_by: null
        rounds: args.rounds or []
        round_start: Rounds.find({}).count() # approx; server will fix up
    renameRoundGroup: (args) ->
      check @userId, NonEmptyString
      renameObject "roundgroups", {args..., who: @userId}
    deleteRoundGroup: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      # disallow deletion unless roundgroup.rounds is empty
      # XXX or else move rounds to some other group(s)
      rg = RoundGroups.findOne(id)
      return false unless rg? and rg?.rounds?.length is 0
      deleteObject "roundgroups", {id, who: @userId}

    newRound: (args) ->
      check @userId, NonEmptyString
      round_prefix = huntPrefix 'round'
      link = if round_prefix
        "#{round_prefix}#{canonical(args.name)}"
      r = newObject "rounds", {args..., who: @userId},
        incorrectAnswers: []
        solved: null
        solved_by: null
        puzzles: args.puzzles or []
        drive: args.drive or null
        link: args.link or link
      newDriveFolder "rounds", r._id, r.name
      return r
    renameRound: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        id: NonEmptyString
        name: NonEmptyString
      # get drive ID (racy)
      r = Rounds.findOne(args.id)
      drive = r?.drive
      spreadsheet = r?.spreadsheet if drive?
      doc = r?.doc if drive?
      result = renameObject "rounds", {args..., who: @userId}
      # rename google drive folder
      renameDriveFolder args.name, drive, spreadsheet, doc if (result and drive?)
      return result
    deleteRound: (rid) ->
      check @userId, NonEmptyString
      check rid, NonEmptyString
      old = Rounds.findOne(rid)
      # disallow deletion unless round.puzzles is empty
      # XXX or else move puzzles to some other round(s)
      return false unless old? and old?.puzzles?.length is 0
      # get drive ID (racy)
      drive = old?.drive
      # remove round itself
      r = deleteObject "rounds", {id: rid, who: @userId}
      # remove from all roundgroups
      RoundGroups.update { rounds: rid },{ $pull: rounds: rid },{ multi: true }
      # delete google drive folder and all contents, recursively
      deleteDriveFolder drive if drive?
      # XXX: delete chat room logs?
      return r

    newPuzzle: (args) ->
      check @userId, NonEmptyString
      puzzle_prefix = huntPrefix 'puzzle'
      link = if puzzle_prefix
        "#{puzzle_prefix}#{canonical(args.name)}"
      p = newObject "puzzles", {args..., who: @userId},
        incorrectAnswers: []
        solved: null
        solved_by: null
        drive: args.drive or null
        spreadsheet: args.spreadsheet or null
        doc: args.doc or null
        link: args.link or link
      # create google drive folder (server only)
      newDriveFolder "puzzles", p._id, p.name
      return p
    renamePuzzle: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        id: NonEmptyString
        name: NonEmptyString
      # get drive ID (racy)
      p = Puzzles.findOne args.id
      drive = p?.drive
      spreadsheet = p?.spreadsheet if drive?
      doc = p?.doc if drive?
      result = renameObject "puzzles", {args..., who: @userId}
      # rename google drive folder
      renameDriveFolder args.name, drive, spreadsheet, doc if result and drive?
      return result
    deletePuzzle: (pid) ->
      check @userId, NonEmptyString
      check pid, NonEmptyString
      # get drive ID (racy)
      old = Puzzles.findOne pid
      drive = old?.drive
      # remove puzzle itself
      r = deleteObject "puzzles", {id: pid, who: @userId}
      # remove from all rounds
      Rounds.update { puzzles: pid },{ $pull: puzzles: pid },{ multi: true }
      # delete google drive folder
      deleteDriveFolder drive if drive?
      # XXX: delete chat room logs?
      return r

    newCallIn: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidAnswerType
        target: IdOrObject
        answer: NonEmptyString
        backsolve: Match.Optional(Boolean)
        provided: Match.Optional(Boolean)
      return if this.isSimulation # otherwise we trigger callin sound twice
      id = args.target._id or args.target
      name = collection(args.type).findOne(args.target)?.name
      throw new Meteor.Error(400, "bad target") unless name?
      backsolve = if args.backsolve then " [backsolved]" else ''
      provided = if args.provided then " [provided]" else ''
      newObject "callins", {name:name+':'+args.answer, who:@userId},
        type: args.type
        target: id
        answer: args.answer
        who: @userId
        submitted_to_hq: false
        backsolve: !!args.backsolve
        provided: !!args.provided
      , {suppressLog:true}
      body = (opts) ->
        "is requesting a call-in for #{args.answer.toUpperCase()}" + \
        (if opts?.specifyPuzzle then " (#{name})" else "") + provided + backsolve
      msg =
        action: true
        nick: @userId
      # send to the general chat
      msg.body = body(specifyPuzzle: true)
      unless args?.suppressRoom is "general/0"
        Meteor.call 'newMessage', msg
      # send to the puzzle chat
      msg.body = body(specifyPuzzle: false)
      msg.room_name = "#{args.type}/#{id}"
      unless args?.suppressRoom is msg.room_name
        Meteor.call 'newMessage', msg
      # send to the round chat
      if args.type is "puzzles"
        round = Rounds.findOne puzzles: id
        if round?
          msg.body = body(specifyPuzzle: true)
          msg.room_name = "rounds/#{round._id}"
          unless args?.suppressRoom is msg.room_name
            Meteor.call "newMessage", msg
      oplog "New answer #{args.answer} submitted for", args.type, id, \
          @userId, 'callins'

    newQuip: (text) ->
      check @userId, NonEmptyString
      check text, NonEmptyString
      # "Name" of a quip is a random name based on its hash, so the
      # oplogs don't spoil the quips.
      name = if Meteor.isSimulation
        text.slice(0, 16) # placeholder
      else
        RandomName(seed: text)
      newObject "quips", {name:name, who:@userId},
        text: text
        last_used: 0 # not yet used
        use_count: 0 # not yet used

    useQuip: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        id: NonEmptyString
        punted: Match.Optional(Boolean)
      quip = Quips.findOne args.id
      throw new Meteor.Error(400, "bad quip id") unless quip
      now = UTCNow()
      Quips.update args.id,
        $set: {last_used: now, touched: now, touched_by: @userId}
        $inc: use_count: (if args.punted then 0 else 1)
      return if args.punted
      quipAddUrl = # see Router.urlFor
        Meteor._relativeToSiteRootUrl "/quips/new"

      Meteor.call 'newMessage',
        body: "<span class=\"bb-quip-action\">#{UI._escape(quip.text)} <a class='quips-link' href=\"#{quipAddUrl}\"></a></span>"
        action: true
        bodyIsHtml: true

    removeQuip: (id) ->
      check @userId, NonEmptyString
      deleteObject "quips", {id, who: @userId}

    correctCallIn: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      callin = CallIns.findOne id
      throw new Meteor.Error(400, "bad callin") unless callin
      # call-in is cancelled as a side-effect of setAnswer
      Meteor.call "setAnswer",
        type: callin.type
        target: callin.target
        answer: callin.answer
        backsolve: callin.backsolve
        provided: callin.provided
      backsolve = if callin.backsolve then "[backsolved] " else ''
      provided = if callin.provided then "[provided] " else ''
      name = collection(callin.type)?.findOne(callin.target)?.name
      msg =
        body: "reports that #{provided}#{backsolve}#{callin.answer.toUpperCase()} is CORRECT!"
        action: true
        room_name: "#{callin.type}/#{callin.target}"

      # one message to the puzzle chat
      Meteor.call 'newMessage', msg

      # one message to the general chat
      delete msg.room_name
      msg.body += " (#{name})" if name?
      Meteor.call 'newMessage', msg

      # one message to the round chat for metasolvers
      round = Rounds.findOne puzzles: callin.target
      if round?
        msg.room_name = "rounds/#{round._id}"
        Meteor.call 'newMessage', msg

    incorrectCallIn: (id) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      callin = CallIns.findOne id
      throw new Meteor.Error(400, "bad callin") unless callin
      # call-in is cancelled as a side-effect of addIncorrectAnswer
      Meteor.call "addIncorrectAnswer",
        type: callin.type
        target: callin.target
        answer: callin.answer
        backsolve: callin.backsolve
        provided: callin.provided
      name = collection(callin.type)?.findOne(callin.target)?.name
      msg =
        body: "sadly relays that #{callin.answer.toUpperCase()} is INCORRECT."
        action: true
        room_name: "#{callin.type}/#{callin.target}"
      Meteor.call 'newMessage', msg
      delete msg.room_name
      msg.body += " (#{name})" if name?
      Meteor.call 'newMessage', msg

    cancelCallIn: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        id: NonEmptyString
        suppressLog: Match.Optional(Boolean)
      callin = CallIns.findOne(args.id)
      throw new Meteor.Error(400, "bad callin") unless callin
      unless args.suppressLog
        oplog "Canceled call-in of #{callin.answer} for", callin.type, \
            callin.target, @userId
      deleteObject "callins",
        id: args.id
        who: @userId
      , {suppressLog:true}

    locateNick: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        location:
          type: 'Point'
          coordinates: ArrayMembers [NumberInRange(min: -180, max:180), NumberInRange(min: -90, max: 90)]
        timestamp: Match.Optional(Number)
      return if this.isSimulation # server side only
      # the server transfers updates from priv_located* to located* at
      # a throttled rate to prevent N^2 blow up.
      # priv_located_order implements a FIFO queue for updates, but
      # you don't lose your place if you're already in the queue
      timestamp = UTCNow()
      n = Meteor.users.update @userId,
        $set:
          priv_located: args.timestamp ? timestamp
          priv_located_at: args.location
        $min: priv_located_order: timestamp
      throw new Meteor.Error(400, "bad userId: #{@userId}") unless n > 0

    newMessage: (args) ->
      check @userId, NonEmptyString
      check args, Object
      return if this.isSimulation # suppress flicker
      newMsg =
        body: args.body or ""
        bodyIsHtml: args.bodyIsHtml or false
        nick: @userId
        system: args.system or false
        action: args.action or false
        to: canonical(args.to or "") or null
        poll: args.poll or null
        room_name: args.room_name or "general/0"
        timestamp: UTCNow()
        useful: args.useful or false
        useless_cmd: args.useless_cmd or false
      if args.oplog
        newMsg.oplog = newMsg.action = newMsg.followup = true
        newMsg.room_name = 'oplog/0'
        newMsg.stream = args.stream or ''
      # translate emojis!
      newMsg.body = emojify newMsg.body unless newMsg.bodyIsHtml
      # update the user's 'last read' message to include this one
      # (doing it here allows us to use server timestamp on message)
      unless (args.suppressLastRead or newMsg.system or newMsg.oplog)
        Meteor.call 'updateLastRead',
          room_name: newMsg.room_name
          timestamp: newMsg.timestamp
      newMsg._id = Messages.insert newMsg
      return newMsg

    setStarred: (id, starred) ->
      check @userId, NonEmptyString
      check id, NonEmptyString
      check starred, Boolean
      # Entirely premature optimization: if starring a message, assume it's
      # recent; if unstarring, assume it's old.
      if starred
        colls = [ Messages, OldMessages]
      else
        colls = [ OldMessages, Messages ]
      for coll in colls
        num = coll.update (
          _id: id
          to: null
          system: $in: [false, null]
          action: $in: [false, null]
          oplog: $in: [false, null]
          presence: null
        ), $set: {starred: starred or null}
        return if num > 0

    updateLastRead: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        room_name: NonEmptyString
        timestamp: Number
      LastRead.upsert
        nick: @userId
        room_name: args.room_name
      , $max:
        timestamp: args.timestamp

    setPresence: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        room_name: NonEmptyString
        present: Match.Optional Boolean
        foreground: Match.Optional Boolean
        uuid: Match.Optional NonEmptyString
      # we're going to do the db operation only on the server, so that we
      # can safely use mongo's 'upsert' functionality.  otherwise
      # Meteor seems to get a little confused as it creates presence
      # entries on the client that don't exist on the server.
      # (meteor does better when it's reconciling the *contents* of
      # documents, not their existence) (this is also why we added the
      # 'presence' field instead of deleting entries outright when
      # a user goes away)
      # IN METEOR 0.6.6 upsert support was added to the client.  So let's
      # try to do this on both sides now.
      #return unless Meteor.isServer
      Presence.upsert
        nick: @userId
        room_name: args.room_name
      , $set:
          timestamp: UTCNow()
          present: args.present or false
      return unless args.present
      # only set foreground if true or foreground_uuid matches; this
      # prevents bouncing if user has two tabs open, and one is foregrounded
      # and the other is not.
      if args.foreground
        Presence.update
          nick: @userId
          room_name: args.room_name
        , $set:
          foreground: true
          foreground_uuid: args.uuid
      else # only update 'foreground' if uuid matches
        Presence.update
          nick: @userId
          room_name: args.room_name
          foreground_uuid: args.uuid
        , $set:
          foreground: args.foreground or false
      return

    get: (type, id) ->
      check @userId, NonEmptyString
      check type, NonEmptyString
      check id, NonEmptyString
      return collection(type).findOne(id)

    getByName: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        optional_type: Match.Optional(NonEmptyString)
      for type in ['roundgroups','rounds','puzzles']
        continue if args.optional_type and args.optional_type isnt type
        o = collection(type).findOne canon: canonical(args.name)
        return {type:type,object:o} if o
      unless args.optional_type and args.optional_type isnt 'nicks'
        o = Meteor.users.findOne canonical args.name
        return {type: 'nicks', object: o} if o
      # try RxPy notation
      if /^r\d+(p\d+)?$/i.test(args.name)
        [_,round,puzzle] = args.name.split /\D+/
        return Meteor.call 'getByRP',
          round: +round
          puzzle: if puzzle? then +puzzle
      return null # no match found

    # parse RxPy notation.
    getByRP: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        round: Number
        puzzle: Match.Optional(Number)
      rg = RoundGroups.findOne({
        round_start: $lte: (args.round-1)
      },{
        sort:[['round_start','desc']]
      })
      rid = if rg? then rg.rounds[args.round - rg.round_start - 1]
      r = if rid? then Rounds.findOne(rid)
      return { type: 'rounds', object: r } if r? and not args.puzzle?
      pid = if r? then r.puzzles[args.puzzle - 1]
      p = if pid? then Puzzles.findOne(pid)
      return { type: 'puzzles', object: p } if p?
      null

    setField: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidType
        object: IdOrObject
        fields: Object
      id = args.object._id or args.object
      now = UTCNow()
      # disallow modifications to the following fields; use other APIs for these
      for f in ['name','canon','created','created_by','solved','solved_by',
               'tags','rounds','round_start','puzzles','incorrectAnswers',
               'located','located_at',
               'priv_located','priv_located_at','priv_located_order']
        delete args.fields[f]
      args.fields.touched = now
      args.fields.touched_by = @userId
      collection(args.type).update id, $set: args.fields
      return true

    setTag: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        type: ValidType
        object: IdOrObject
        value: String
      # bail to setAnswer/deleteAnswer if this is the 'answer' tag.
      if canonical(args.name) is 'answer'
        return Meteor.call (if args.value then "setAnswer" else "deleteAnswer"),
          type: args.type
          target: args.object
          answer: args.value
      if canonical(args.name) is 'link'
        args.fields = { link: args.value }
        return Meteor.call 'setField', args
      args.now = UTCNow() # don't let caller lie about the time
      updateDoc = $set:
        touched: args.now
        touched_by: @userId
      id = args.object._id or args.object
      setTagInternal updateDoc, {args..., who: @userId}
      0 < collection(args.type).update id, updateDoc

    deleteTag: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        name: NonEmptyString
        type: ValidType
        object: IdOrObject
      id = args.object._id or args.object
      # bail to deleteAnswer if this is the 'answer' tag.
      if canonical(args.name) is 'answer'
        return Meteor.call "deleteAnswer",
          type: args.type
          target: args.object
      if canonical(args.name) is 'link'
        args.fields = { link: null }
        return Meteor.call 'setField', args
      args.now = UTCNow() # don't let caller lie about the time
      updateDoc = $set:
        touched: args.now
        touched_by: @userId
      deleteTagInternal updateDoc, args.name
      0 < collection(args.type).update id, updateDoc

    summon: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        object: IdOrObject
        type: ValidAnswerType
        how: Match.Optional(NonEmptyString)
      id = args.object._id or args.object
      obj = collection(args.type).findOne id
      if not obj?
        return "Couldn't find #{pretty_collection args.type} #{id}"
      if obj.solved
        return "#{pretty_collection args.type} #{obj.name} is already answered"
      wasStuck = isStuck obj
      rawhow = args.how or 'Stuck'
      how = if rawhow.toLowerCase().startsWith('stuck') then rawhow else "Stuck: #{rawhow}"
      Meteor.call 'setTag',
        object: id
        type: args.type
        name: 'Status'
        value: how
        now: UTCNow()
      if isStuck obj
        return
      oplog "Help requested for", args.type, id, @userid, 'stuck'
      body = "has requested help: #{rawhow}"
      Meteor.call 'newMessage',
        action: true
        body: body
        room_name: "#{args.type}/#{id}"
      objUrl = # see Router.urlFor
        Meteor._relativeToSiteRootUrl "/#{args.type}/#{id}"
      body = "has requested help: #{UI._escape rawhow} (#{pretty_collection args.type} <a class=\"#{UI._escape args.type}-link\" href=\"#{objUrl}\">#{UI._escape obj.name}</a>)"
      Meteor.call 'newMessage',
        action: true
        bodyIsHtml: true
        body: body
      return

    unsummon: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        object: IdOrObject
        type: ValidAnswerType
      id = args.object._id or args.object
      obj = collection(args.type).findOne id
      if not obj?
        return "Couldn't find #{pretty_collection args.type} #{id}"
      if not (isStuck obj)
        return "#{pretty_collection args.type} #{obj.name} isn't stuck"
      oplog "Help request cancelled for", args.type, id, @userId
      sticker = obj.tags.status?.touched_by
      Meteor.call 'deleteTag',
        object: id
        type: args.type
        name: 'status'
        now: UTCNow()
      body = "has arrived to help"
      if @userId is sticker
        body = "no longer needs help getting unstuck"
      Meteor.call 'newMessage',
        action: true
        body: body
        room_name: "#{args.type}/#{id}"
      body = "#{body} in #{pretty_collection args.type} #{obj.name}"
      Meteor.call 'newMessage',
        action: true
        body: body
      return

    addRoundToGroup: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        round: IdOrObject
        group: IdOrObject
      rid = args.round._id or args.round
      gid = args.group._id or args.group
      rg = RoundGroups.findOne(gid)
      throw new Meteor.Error(400, "bad group") unless rg
      # remove round from all other groups
      RoundGroups.update { rounds: rid },{ $pull: rounds: rid },{ multi: true }
      # add round to the given group
      if args.before or args.after
        # add to a specific location
        rounds = (r for r in rg.rounds when r != rid)
        nrounds = rounds[..]
        if args.before
          npos = rounds.indexOf(args.before)
        else
          npos = rounds.indexOf(args.after) + 1
        nrounds.splice(npos, 0, rid)
        # update the collection only if there wasn't a race
        RoundGroups.update {_id: gid, rounds: rounds}, $set: rounds: nrounds
      # add to the end (no-op if the 'at' clause succeeded)
      RoundGroups.update gid, $addToSet: rounds: rid
      return true

    addPuzzleToRound: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        puzzle: IdOrObject
        round: IdOrObject
      pid = args.puzzle._id or args.puzzle
      rid = args.round._id or args.round
      check rid, NonEmptyString
      r = Rounds.findOne(rid)
      throw new Meteor.Error(400, "bad round") unless r
      # remove puzzle from all other rounds
      Rounds.update { puzzles: pid },{ $pull: puzzles: pid },{ multi: true }
      # add puzzle to the given round
      if args.before or args.after
        # add to a specific location
        puzzles = (p for p in r.puzzles when p != pid)
        npuzzles = puzzles[..]
        if puzzles.length == 0
          npos = 0
        else if args.before
          npos = puzzles.indexOf(args.before)
        else
          npos = puzzles.indexOf(args.after) + 1
        npuzzles.splice(npos, 0, pid)
        # update the collection only if there wasn't a race
        Rounds.update {_id: rid, puzzles: puzzles}, $set: puzzles: npuzzles
      # add to the end (no-op if the 'at' clause succeeded)
      Rounds.update rid, $addToSet: puzzles: pid
      return true

    getRoundForPuzzle: (puzzle) ->
      check @userId, NonEmptyString
      check puzzle, IdOrObject
      id = puzzle._id or puzzle
      check id, NonEmptyString
      return Rounds.findOne(puzzles: id)

    getGroupForRound: (round) ->
      check @userId, NonEmptyString
      check round, IdOrObject
      id = round._id or round
      return RoundGroups.findOne(rounds: id)

    moveUp: (args) ->
      check @userId, NonEmptyString
      moveObject(args.type, args.id, "up")

    moveDown: (args) ->
      check @userId, NonEmptyString
      moveObject(args.type, args.id, "down")

    setAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidAnswerType
        target: IdOrObject
        answer: NonEmptyString
        backsolve: Match.Optional(Boolean)
        provided: Match.Optional(Boolean)
      id = args.target._id or args.target

      # Only perform the update and oplog if the answer is changing
      oldAnswer = collection(args.type).findOne(id)?.tags.answer?.value
      if oldAnswer is args.answer
        return false

      now = UTCNow()
      updateDoc = $set:
        solved: now
        solved_by: @userId
        touched: now
        touched_by: @userId
      setTagInternal updateDoc,
        name: 'Answer'
        value: args.answer
        who: @userId
        now: now
      deleteTagInternal updateDoc, 'status'
      if args.backsolve
        setTagInternal updateDoc,
          name: 'Backsolve'
          value: 'yes'
          who: @userId
          now: now
      else
        deleteTagInternal updateDoc, 'Backsolve'
      if args.provided
        setTagInternal updateDoc,
          name: 'Provided'
          value: 'yes'
          who: @userId
          now: now
      else
        deleteTagInternal updateDoc, 'Provided'
      updated = collection(args.type).update
        _id: id
        'tags.answer.value': $ne: args.answer
      , updateDoc
      return false if updated is 0
      oplog "Found an answer (#{args.answer.toUpperCase()}) to", args.type, id, @userId, 'answers'
      # cancel any entries on the call-in queue for this puzzle
      for c in CallIns.find(type: args.type, target: id).fetch()
        Meteor.call 'cancelCallIn',
          id: c._id
          suppressLog: (c.answer is args.answer)
      return true

    addIncorrectAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidAnswerType
        target: IdOrObject
        answer: NonEmptyString
        backsolve: Match.Optional(Boolean)
        provided: Match.Optional(Boolean)
      id = args.target._id or args.target
      now = UTCNow()

      target = collection(args.type).findOne(id)
      throw new Meteor.Error(400, "bad target") unless target
      collection(args.type).update id, $push:
        incorrectAnswers:
          answer: args.answer
          timestamp: UTCNow()
          who: @userId
          backsolve: !!args.backsolve
          provided: !!args.provided

      oplog "reports incorrect answer #{args.answer} for", args.type, id, @userId, \
          'callins'
      # cancel any matching entries on the call-in queue for this puzzle
      for c in CallIns.find(type: args.type, target: id, answer: args.answer).fetch()
        Meteor.call 'cancelCallIn',
          id: c._id
          suppressLog: true
      return true

    deleteAnswer: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidAnswerType
        target: IdOrObject
      id = args.target._id or args.target
      now = UTCNow()
      updateDoc = $set:
        solved: null
        solved_by: null
        touched: now
        touched_by: @userId
      deleteTagInternal updateDoc, 'answer'
      deleteTagInternal updateDoc, 'backsolve'
      deleteTagInternal updateDoc, 'provided'
      collection(args.type).update id, updateDoc
      oplog "Deleted answer for", args.type, id, @userId
      return true

    newPoll: (room, question, options) ->
      console.log arguments
      check @userId, NonEmptyString
      check room, NonEmptyString
      check question, NonEmptyString
      check options, ArrayWithLength(NonEmptyString, {min: 2, max: 5})
      canonOpts = new Set
      opts = for opt in options
        copt = canonical opt
        continue if canonOpts.has copt
        canonOpts.add copt
        {canon: copt, option: opt}
      id = Polls.insert
        created: UTCNow()
        created_by: @userId
        question: question
        options: opts
        votes: {}
      Meteor.call 'newMessage',
        body: question
        room_name: room
        poll: id
      id

    vote: (poll, option) ->
      check @userId, NonEmptyString
      check poll, NonEmptyString
      check option, NonEmptyString
      # This atomically checks that the poll exists and the option is valid,
      # then replaces any existing vote the user made.
      Polls.update
        _id: poll
        'options.canon': option
      ,
        $set: "votes.#{@userId}": {canon: option, timestamp: UTCNow()}

    getRinghuntersFolder: ->
      check @userId, NonEmptyString
      return unless Meteor.isServer
      # Return special folder used for uploads to general Ringhunters chat
      return share.drive.ringhuntersFolder

    # if a round/puzzle folder gets accidentally deleted, this can be used to
    # manually re-create it.
    fixPuzzleFolder: (args) ->
      check @userId, NonEmptyString
      check args, ObjectWith
        type: ValidType
        object: IdOrObject
        name: NonEmptyString
      id = args.object._id or args.object
      newDriveFolder args.type, id, args.name
)()

UTCNow = -> Date.now()

# exports
share.model =
  # constants
  PRESENCE_KEEPALIVE_MINUTES: PRESENCE_KEEPALIVE_MINUTES
  NOT_A_TIMESTAMP: NOT_A_TIMESTAMP
  # collection types
  CallIns: CallIns
  Quips: Quips
  Polls: Polls
  Names: Names
  LastAnswer: LastAnswer
  RoundGroups: RoundGroups
  Rounds: Rounds
  Puzzles: Puzzles
  Messages: Messages
  OldMessages: OldMessages
  Pages: Pages
  LastRead: LastRead
  Presence: Presence
  # helper methods
  collection: collection
  pretty_collection: pretty_collection
  getTag: getTag
  isStuck: isStuck
  canonical: canonical
  drive_id_to_link: drive_id_to_link
  spread_id_to_link: spread_id_to_link
  doc_id_to_link: doc_id_to_link
  UTCNow: UTCNow
