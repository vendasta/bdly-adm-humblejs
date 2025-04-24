###
# HumbleJS
# ========
#
# ODM for MongoDB.
#
###
_ = require 'lodash'
util = require 'util'
moment = require 'moment'
mongojs = require 'mongojs'

# This allows you to control whether queries are automatically mapped
exports.auto_map_queries = true


###
# The database class
###
class Database
  constructor: (args...) ->
    db = mongojs.apply mongojs, args

    Object.defineProperty this, 'collection', get: -> (args...) ->
      db.collection.apply db, args

    callable = (name) ->
      # Extra fancy shortcut for getting the DB instance directly
      if not name?
        return db

      # Super fancy shortcut for getting a collection
      db.collection name
    callable.__proto__ = this
    return callable

  document: (args..., mapping) ->
    collection = @collection.apply @collection, args
    return new Document collection, mapping

exports.Database = Database


###
# The document class
###
class Document
  constructor: (collection, mapping) ->
    Object.defineProperty this, 'collection', get: -> collection

    # Ensure we always have a mapping, even if it's empty
    mapping ?= {}

    # Closure over the document class
    _document = this

    # Create a prototype for the Document instances that already has all
    # the mapped attribute getters and setters
    @instanceProto = {}
    Object.defineProperties @instanceProto,
      # We store the schema for later
      __schema: value: mapping

      # Convenience methods
      save: get: -> (args...) ->
        args.unshift this
        _document.save.apply _document, args

      insert: get: -> (args...) ->
        args.unshift this
        _document.insert.apply _document, args

      update: get: -> (args...) ->
        if not this._id?
          throw new Error "Cannot update without '_id' field"
        args.unshift _id: this._id
        _document.update.apply _document, args

      remove: get: -> (args...) ->
        if not this._id?
          throw new Error "Cannot remove without '_id' field"
        args.unshift _id: this._id
        _document.remove.apply _document, args

      forJson: get: -> (allowDefault = true) ->
        _forJson = (json)->
          for name, value of @
            do (name, value) ->
              # If it's an object, it's either an embedded mapping or a default
              # value schema, which would be an array
              if _.isObject value
                # Handle arrays, which are default values in the schema
                if _.isArray value
                  # Unpack the key name and default value
                  [key, value] = value
                  if key not of json
                    # If we're not doing defaults, just get the fuck out
                    return if not allowDefault
                    # We reverse the order of name, key for this call since
                    # it's the inverse mapping of a normal document
                    value = _getDefault json, key, name, value

                  # We don't want to override the assignment, but we do want to
                  # ensure it's present
                  json[name] = value if key not of json and not _.isArray json
                  return

                # We provide a default object, if it's not set in the key
                _json = json[name] ? {}
                # Make sure if there was a value set that's not an object so
                # we don't continue to try to provide defaults into it
                return if not _.isObject _json

                # Recursively search for defaults within embedded documents
                _forJson.call value, _json

                # Set the recursively generated defaults back to the json if
                # they actually exist
                json[name] = _json unless _.isEmpty _json
                return

          # Return the JSON ready structure
          json

        _forJson.call @__schema, _transform @, @__inverse_schema, {}

    # Recursively map the document class and prototype
    _map @, mapping, @instanceProto

    # Memoize the inverse mapping
    Object.defineProperty @instanceProto, '__inverse_schema',
      value: _invertSchema @instanceProto.__schema

    # This makes the class returned also callable for syntactic sugar's sake
    callable = (doc) =>
      @new doc
    callable.__proto__ = @
    return callable

  # Document wrapper method factory
  _wrap = (method) ->
    get: -> (query, args..., cb) =>
      if exports.auto_map_queries
        # Map queries, which should be the first argument
        if method is 'findAndModify'
          # findAndModify takes a single argument, which has 'query' and
          # 'update' keys which we have to map
          query.query = @_ query.query if query.query?
          query.update = @_ query.update if query.update?
        else if Array.isArray query
          query = (@_ q for q in query)
        else
          query = @_ query

        # If we have arguments, the second argument is going to be a projection
        # or update
        if args.length
          args[0] = @_ args[0]

      # If the callback isn't a function, but has a value (e.g. is an object)
      # it could be a projection or update object, so we want to add it back to
      # the args
      if cb not instanceof Function and cb?
        # Check if it's an object, e.g. a projection or update, and it's the
        # second argument
        if exports.auto_map_queries and (cb is Object cb) and (not args.length)
          cb = @_ cb

        args.push cb
        cb = null

      # Place the query or doc/docs to be saved or inserted back at the head of
      # the arguments
      args.unshift query

      # If there's no callback specified, return a cursor instead
      if method is 'find' and cb not instanceof Function
        return new Cursor @, @collection.find.apply @collection, args

      # This is regular callback mode
      # Wrap these callbacks since they return docs
      args.push @cb cb
      @collection[method].apply @collection, args

  Object.defineProperties @prototype,
    ###
    # Return a new document instance.
    #
    # This is the same as doing ``new MyDocument()``.
    ###
    new: value: (doc) ->
      doc ?= {}
      @wrap doc

    ###
    # MongoJS method wrappers
    ###
    find: _wrap 'find'
    findOne: _wrap 'findOne'
    findAndModify: _wrap 'findAndModify'
    insert: _wrap 'insert'
    update: _wrap 'update'
    count: _wrap 'count'
    remove: _wrap 'remove'
    save: _wrap 'save'

    ###
    # Helper for wrapping documents in a callback.
    ###
    cb: value: (cb) ->
      # This our callback wrapper that will munge the document
      (err, doc) =>
        # No doc or callback? Just get out
        if not doc or not cb
          return cb? err, doc
        # If a document was returned, we define mappings on it
        if Array.isArray doc
          doc = (@wrap d for d in doc)
        else
          doc = @wrap doc
        # We use existence here to make sure we don't try to call non-functions
        cb? err, doc

    ###
    # Wrap an individual document
    ###
    wrap: value: (doc) ->
      _proxy doc, @instanceProto

    ###
    # Transform keys in a query document into their mapped counterpart
    ###
    _: value: (doc) ->
      schema = @instanceProto.__schema
      dest = {}
      _transform doc, schema, dest


exports.Document = Document


###
# Cursor which wraps MongoJS cursors ensuring we get document mappings.
###
# TODO: shakefu test cursor chaining to ensure that it continues to wrap the
# cursor
class Cursor
  constructor: (@document, @cursor) ->

  # Wrapper method factory
  _wrap = (method) ->
    get: -> (args..., cb) ->
      # If we don't have a callback, then we are chaining the cursor
      if cb not instanceof Function
        # If there's only one argument, it always gets assigned to 'cb', so if
        # it's not a function and it exists, we add it back to args to apply
        args.push cb if cb?
        return new Cursor @document, @cursor[method].apply @cursor, args
      # Otherwise we wrap the callback to return Document instances
      args.push @document.cb cb
      @cursor[method].apply @cursor, args

  # Used for methods which return documents, not cursors
  _wrap_doc = (method) ->
    get: -> (args..., cb) ->
      # If we don't have a callback, then we are trying to chain the cursor,
      # which should throw an error for these methods, but we let the
      # underlying implementation do that for us
      if cb not instanceof Function
        # If there's only one argument, it always gets assigned to 'cb', so
        # if it's not a function and it exists, we add it back to args to
        # apply
        args.push cb if cb?
        return new Cursor @document, @cursor[method].apply @cursor, args
      # Otherwise we wrap the callback to return Document instances
      args.push @document.cb cb
      @cursor[method].apply @cursor, args

  Object.defineProperties @prototype,
    batchSize: _wrap 'batchSize'
    count: _wrap_doc 'count'
    explain: _wrap_doc 'explain'
    forEach: _wrap 'forEach'
    limit: _wrap 'limit'
    map: _wrap_doc 'map'
    next: _wrap_doc 'next'
    skip: _wrap 'skip'
    sort: _wrap 'sort'
    toArray: _wrap_doc 'toArray'
    rewind: _wrap 'rewind'
    destroy: _wrap 'destroy'


###
# Embedded documents
###
class EmbeddedDocument
  constructor: (key, mapping) ->
    Object.defineProperties @,
      key: value: key
      mapping: value: mapping
      isEmbed: value: true

    for key, value of mapping
      @[key] = value

# This is a thin wrapper around EmbeddedDocument so we don't need to use the
# new keyword when instantiating document schemas
Embed = (key, mapping) ->
  new EmbeddedDocument key, mapping

exports.Embed = Embed


###
# Sparse reports
###
class SparseReport extends Document
  @MINUTE: 'minute'
  @HOUR: 'hour'
  @DAY: 'day'
  @WEEK: 'week'
  @MONTH: 'month'
  @YEAR: 'year'

  constructor: (collection, mapping, @options) ->
    # Provide defaults to the attribute mapping for being lazy
    mapping = _.defaults mapping,
      total: 'total'
      all: 'all'
      events: 'events'
      timestamp: 'timestamp'
      expires: 'expires'

    # Initialize the document superclass
    super collection, mapping

    # Provide default options
    @options ?= {}
    @options = _.defaults @options,
      sum: true
      id_mark: '#'

    # Make sparse report instances creatable with the new keyword
    callable = (doc) =>
      @new doc
    callable.__proto__ = @
    return callable

  # Helper for getting a unix timestamp
  getTimestamp: (timestamp) ->
    timestamp ?= new Date()
    timestamp = @getPeriod timestamp
    timestamp = timestamp.unix()

  # Helper for getting the current start of `timestamp`'s period
  getPeriod: (timestamp) ->
    moment.utc(timestamp).startOf @options.period

  # Helper for creating the _id string used by the docs
  getId: (identifier, timestamp) ->
    timestamp = @getTimestamp timestamp
    "#{identifier}#{@options.id_mark}#{_pad timestamp, 15}"

  # Generates a random timestamp outside the document period to use for a TTL
  # index expiry timestamp
  getExpiry: (timestamp) ->
    day = 60 * 60 * 24
    week = day * 7
    # Generate a random offset between one day and a week
    offset = Math.random() * (week - day) + day
    timestamp = moment.utc(timestamp).add 1, @options.period
    moment.utc(timestamp).add offset, 'seconds'

  ###
  # Record events
  ###
  record: (identifier, events, timestamp, callback) ->
    # The timestamp is optional
    if _.isFunction timestamp
      callback = timestamp
      timestamp = undefined

    # Get the ID string and period start timestamp
    _id = @getId identifier, timestamp
    timestamp = @getPeriod(timestamp).toDate()
    expiry = @getExpiry(timestamp).toDate()

    # Build our update increment clause
    update = {}
    # Keep a total count
    update[@total] = 1
    if _.isNumber(events)
      # If events was provided as a number, then we use that for the total
      update[@total] = events
    else
      # Otherwise, we traverse the evense object to build our update keys
      for key of events
        update[@events + '.' + key] = events[key]
        # If a given event key has a higher total, we use that one, rather than
        # summing the total of all the subkeys - this may be a behavior we want
        # to make optional or change later
        if events[key] > update[@total]
          update[@total] = events[key]

    # Set our period timestamp on the document
    updateTimestamp = {}
    updateTimestamp[@timestamp] = timestamp
    updateTimestamp[@expires] = expiry

    # Create or update the document
    @findAndModify
      query: _id: _id
      update:
        $set: updateTimestamp
        $inc: update
      new: true
      upsert: true
      callback

  ###
  # Return a report for `identifier` between `start` and `end` dates
  ###
  get: (identifier, start, end, callback) ->
    _this = @
    # Handle optional arguments
    if _.isFunction start
      [start, callback] = [undefined, start]

    if _.isFunction end
      [end, callback] = [undefined, end]

    # Get our start and ending date if not provided
    start ?= new Date()
    end ?= new Date()
    # And our start and ending IDs
    startId = @getId identifier, start
    endId = @getId identifier, end

    # Query for our documents
    @find
      _id:
        $gte: startId
        $lte: endId
      (err, docs) ->
        return callback(err, docs) if err
        # The returned document includes the total count, the count per period
        # and the count for each event subkey
        compiled =
          total: 0
          all: []
          events: {}

        # Create a hash for compiling the totals for each period, and
        # initialize it to zeroes
        periods = _this.dateRange start, end
        all = {}
        for period in periods
          all[period.getTime()] = 0

        # Helper method for going through the report docs
        compiler = (comp, doc) ->
          for key of doc
            val = doc[key]
            if _.isNumber val
              comp[key] ?= 0
              comp[key] += val
            else if _.isObject val
              comp[key] ?= {}
              compiler comp[key], val
            else
              # It shouldn't be anything other than a number
              throw new Error "Expected number, got #{typeof val}"

        # Go through all the documents found and aggregate their numbers
        for doc in docs
          compiled.total += doc.total ? 0
          all[doc.timestamp.getTime()] = doc.total ? 0
          compiler compiled.events, doc.events

        # Go through the totals for each period and put them onto the all
        # array. This might be inefficient for very large queries, and might
        # rely on the JS engine preserving the correct key order, but it works
        for period of all
          compiled.all.push all[period]

        callback err, compiled

  ###
  # Return a range of period dates between `start` and `end`, inclusive.
  ###
  dateRange: (start, end) ->
    start = @getPeriod start
    end = @getPeriod end
    range = []
    range.push start.toDate()

    current = moment(start)
    current.add 1, @options.period
    while current.isBefore(end) or current.isSame(end)
      range.push moment(current).toDate()
      current.add 1, @options.period

    return range

exports.SparseReport = SparseReport


###
# Helper to pad a number with leading zeros as a string.
###
_pad = (num, size) ->
  return num unless num.toString().length < size
  if num >= 0
    return (Math.pow(10, size) + Math.floor(num)).toString().substring(1)
  return '-'+(Math.pow(10, size-1) + Math.floor(0-num)).toString().substring(1)


###
# Helper to proxy an object prototype for instances
###
_proxy = (obj, proto) ->
  # Create a proxy object so that assignments don't affect the prototype
  proxy = {}
  proxy.__proto__ = proto
  # Swap the obj's prototype for our proxy
  obj.__proto__ = proxy
  obj


###
# Helper to recursively map properties on and build instance prototypes
###
_map = (obj, mapping, proto, parent_key) ->
  for name, key of mapping
    do (name, key) ->
      if key.isEmbed
        embed = key
        key = embed.key
        # We have to wrap the string key in a String object so we can add more
        # objerties to it
        embed_key = if parent_key then parent_key + '.' + key else key
        embed_key = new String embed_key

        # Define the mapped property
        Object.defineProperty obj, name,
          value: embed_key
          enumerable: true

        # Create the object we use for the embed prototypes
        embed_proto = {}
        # If we it's an embedded array, we need a different prototype
        array_proto = {}
        array_proto.__proto__ = Array.prototype
        # Add a .new() method to embedded arrays to allow creation of new
        # mapped embedded documents conveniently
        Object.defineProperty array_proto, 'new', value: ->
          new_obj = {}
          @.push new_obj
          return _proxy new_obj, embed_proto

        # Define the property on the instance prototype
        Object.defineProperty proto, name,
          get: ->
            # If the value exists in the doc, just return it
            if key of @
              if name is key
                # We have to swap the prototype out here to prevent recursively
                # calling the get descriptor
                @.__proto__ = Object.prototype
                existing = @[key]
                @.__proto__ = proto
                # The existing value may be undefined if it was an attribute
                # whose name matched its key, and in that case we create a new
                # key with an empty object
                @[key] = existing = {} if not existing?
              else
                existing = @[key]

              if Array.isArray existing
                # If we have an array, we need to map all the embedded
                # documents in that array
                for item in existing
                  _proxy item, embed_proto
                # As well as add the 'new' method to the array itself
                existing = _proxy existing, array_proto
              else
                existing = _proxy existing, embed_proto
              return existing

            # Embeds don't support defaults right now, but if they did, that
            # code would go right here

            # For embedded items we have to save back a new object that we can
            # hold subproperties on
            value = {}
            @[key] = value
            return _proxy value, embed_proto
          set: (value) ->
            if name is key
              # Avoiding infinite recursion by temporarily swapping out the
              # prototype for a plain object.
              @.__proto__ = Object.prototype
              @[key] = value
              @.__proto__ = proto
              return @[key]
            @[key] = value

        # Save the submapping onto the Embed prototype
        Object.defineProperty embed_proto, '___schema', value: embed.mapping

        # Recursively map embedded keys
        _map embed_key, embed.mapping, embed_proto, embed_key
      else
        if Array.isArray key
          # Split the key into the key and default value
          [key, value] = key

        # Add the property to the object we're maping
        if parent_key
          class_key = new String parent_key + '.' + key
          Object.defineProperty obj, name,
            value: class_key
            enumerable: true
          Object.defineProperty obj[name], 'key', value: key
        else
          Object.defineProperty obj, name,
            value: key
            enumerable: true

        # Define the property on the instance prototype
        Object.defineProperty proto, name,
          configurable: true
          get: ->
            _getDefault @, name, key, value
          set: (value) ->
            if name is key
              # Same as above, in the get: method, we're avoiding infinite
              # recursion by temporarily swapping out the prototype for a plain
              # object.
              @.__proto__ = Object.prototype
              @[key] = value
              @.__proto__ = proto
              return @[key]
            @[key] = value


###
# Helper to get a default value
###
_getDefault = (doc, name, key, value) ->
  if name is key
    # This is a nasty, gnarly hack that removes the descriptor behavior defined
    # on the prototype temporarily so we can try to access the value. Without
    # this hack, this causes infinite recursion as the descriptor calls itself.
    proto = doc.__proto__
    doc.__proto__ = Object.prototype
    if key of doc
      val = doc[key]
    doc.__proto__ = proto
    return val if val
  # If the value exists in the doc, just return it
  else if key of doc
    return doc[key]
  # Store callable defaults onto the doc
  val = value?()
  if val isnt undefined
    doc[key] = val
    return val
  # Return either the calc'd/stored default, or the raw default
  return value


###
# Helper to map a document or query to a key set
###
_transform = (doc, schema, dest) ->
  # Don't want to treat strings as objects like the "for of" below will do
  if typeof doc != 'object' # note: an array is an "object" too
    return doc

  for name, value of doc
    if name[0] == '$'
      # If we have a special key, we pretty much skip transforming it and
      # attempt to continue transforming subdocs
      if Array.isArray value
        dest[name] = (_transform v, schema, {} for v in value)
      else
        dest[name] = {}
        _transform value, schema, dest[name]
      continue
    if '.' in name
      # If the name is a dot-notation key, then we try to transform the parts
      name = _transformDotted name, schema
    if name of schema
      # If we have a name in the schema, then we we need to transform it, and
      # possibly handle embedded and arrays
      key = schema[name]
      # Handle keys which have default values
      if Array.isArray key
        key = key[0]
      key_name = if key.isEmbed then key.key else key
      if key.isEmbed
        # If it's embedded, we have to check if it's an array, or recursively
        # map the embedded document
        if Array.isArray value
          # Recursively map all the subdocs in the array
          dest[key_name] = (_transform v, key, {} for v in value)
        else
          # Not an array? Check if it's an object or primitive
          if value is Object value
            dest[key_name] = {}
            _transform value, key, dest[key_name]
          else
            # Must be a primitive
            dest[key_name] = value
      else
        # Not an embedded doc, so we just transform the key
        dest[key_name] = value
    else
      # This isn't a mapped property, so we just add it back
      dest[name] = value
  dest


###
# Helper to map dotted notation property names to key names
###
_transformDotted = (name, schema) ->
  if '.' not in name
    # If there's no more dots, we just attempt to transform the name assuming
    # the schema is still an object
    if schema instanceof Object and name of schema
      key = schema[name]
      if Array.isArray key
        [key, default_value] = key
      key = if key.isEmbed then key.key else key
      return key
    else
      return name

  # If we're here, there's more dots to map
  dot = name.indexOf '.'
  parts = name.slice dot + 1
  name = name.slice 0, dot

  # This could be redone with a stack instead of recursively, but I'd be
  # surprised if anyone embeds more than 1-2 levels within a doc, so meh
  if schema instanceof Object and name of schema
    key = schema[name]
    key = if key.isEmbed then key.key else key
    return key + '.' + _transformDotted parts, schema[name]
  else
    return name + '.' + parts


###
# Helper to invert object keys
###
_invertSchema = (schema) ->
  inverse = {}
  for key, value of schema
    if value.isEmbed
      inverse[value.key] = Embed key, _invertSchema value.mapping
    else if Array.isArray value
      [value, default_value] = value
      inverse[value] = key
    else
      inverse[value] = key
  inverse

