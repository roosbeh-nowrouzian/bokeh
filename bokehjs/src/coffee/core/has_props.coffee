import * as Backbone from "./backbone"
import {logger} from "./logging"
import * as property_mixins from "./property_mixins"
import * as refs from "./util/refs"
import * as p from "./properties"
import {uniqueId} from "./util/string"
import {max} from "./util/array"
import {extend, values, clone, isEmpty} from "./util/object"
import {isString, isObject, isArray} from "./util/types"

export class HasProps extends Backbone.Model

  props: {}
  mixins: []

  @define: (object) ->
    for name, prop of object
      do (name, prop) =>
        if this.prototype.props[name]?
          throw new Error("attempted to redefine property '#{this.name}.#{name}'")

        if this.prototype[name]?
          throw new Error("attempted to redefine attribute '#{this.name}.#{name}'")

        Object.defineProperty(this.prototype, name, {
          # XXX: don't use tail calls in getters/setters due to https://bugs.webkit.org/show_bug.cgi?id=164306
          get: ()      -> value = this.getv(name); return value
          set: (value) -> this.setv(name, value); return this
        }, {
          configurable: false
          enumerable: true
        })

        [type, default_value, internal] = prop
        refined_prop = {
          type: type
          default_value: default_value
          internal: internal ? false
        }

        props = clone(this.prototype.props)
        props[name] = refined_prop
        this.prototype.props = props

  @internal: (object) ->
    _object = {}
    for name, prop of object
      do (name, prop) =>
        [type, default_value] = prop
        _object[name] = [type, default_value, true]
    @define(_object)

  @mixin: (names...) ->
    @define(property_mixins.create(names))
    mixins = this.prototype.mixins.concat(names)
    this.prototype.mixins = mixins

  @mixins: (names) -> @mixin(names...)

  @override: (name_or_object, default_value) ->
    if isString(name_or_object)
      object = {}
      object[name] = default_value
    else
      object = name_or_object

    for name, default_value of object
      do (name, default_value) =>
        value = this.prototype.props[name]
        if not value?
          throw new Error("attempted to override nonexistent '#{this.name}.#{name}'")
        props = clone(this.prototype.props)
        props[name] = extend({}, value, { default_value: default_value })
        this.prototype.props = props

  @define {
    id: [ p.Any ]
  }

  toString: () -> "#{@type}(#{@id})"

  constructor : (attributes, options) ->
    @document = null

    ## straight from backbone.js
    attrs = attributes || {}
    if not options
      options = {}
    this.attributes = {}

    @properties = {}
    for name, {type, default_value} of @props
      if not type?
        throw new Error("undefined property type for #{@type}.#{name}")
      @properties[name] = new type({obj: @, attr: name, default_value: default_value})

    # Bokeh specific
    this._set_after_defaults = {}

    this.setv(attrs, options)

    # this is maintained by backbone ("changes since the last
    # setv()") and probably isn't relevant to us
    this.changed = {}

    ## bokeh custom constructor code

    # setting up data structures for properties
    @_computed = {}

    # auto generating ID
    if not attrs.id?
      this.id = uniqueId(this.type)

    # allowing us to defer initialization when loading many models
    # when loading a bunch of models, we want to do initialization as a second pass
    # because other objects that this one depends on might not be loaded yet

    if not options.defer_initialization
      this.initialize.apply(this, arguments)

  setv: (key, value, options) ->
    # backbones set function supports 2 call signatures, either a dictionary of
    # key value pairs, and then options, or one key, one value, and then options.
    # replicating that logic here
    if isObject(key) or key == null
      attrs = key
      options = value
    else
      attrs = {}
      attrs[key] = value
    for own key, val of attrs
      prop_name = key
      if not @props[prop_name]?
        throw new Error("property #{@type}.#{prop_name} wasn't declared")

      if not (options? and options.defaults)
        @_set_after_defaults[key] = true
    if not isEmpty(attrs)
      old = {}
      for key, value of attrs
        old[key] = @getv(key)
      super(attrs, options)

      if not options?.silent?
        for key, value of attrs
          @_tell_document_about_change(key, old[key], @getv(key), options)

  add_dependencies:  (prop_name, object, fields) ->
    # * prop_name - name of property
    # * object - object on which dependencies reside
    # * fields - attributes on that object
    if not isArray(fields)
      fields = [fields]
    prop_spec = @_computed[prop_name]
    prop_spec.dependencies = prop_spec.dependencies.concat(
      obj: object
      fields: fields
    )
    # bind depdencies to change dep callback
    for fld in fields
      @listenTo(object, "change:" + fld, prop_spec['callbacks']['changedep'])

  define_computed_property: (prop_name, getter, use_cache=true) ->
    # #### Parameters
    # * prop_name: name of property
    # * getter: function, calculates computed value, takes no arguments
    # * use_cache: whether to cache or not
    # #### Returns
    # * prop_spec: specification of the property, with the getter,

    if @props[prop_name]?
      #throw new Error(
      console.log("attempted to redefine existing property #{@type}.#{prop_name}")

    if @_computed[prop_name]?
      throw new Error("attempted to redefine existing computed property #{@type}.#{prop_name}")

    changedep = () =>
      @trigger('changedep:' + prop_name)

    propchange = () =>
      firechange = true
      if prop_spec['use_cache']
        old_val = prop_spec.cache
        prop_spec.cache = undefined
        new_val = @_get_computed(prop_name)
        firechange = new_val != old_val
      if firechange
        @trigger('change:' + prop_name, this, @_get_computed(prop_name))
        @trigger('change', this)

    prop_spec =
      'getter': getter,
      'dependencies': [],
      'use_cache': use_cache
      'callbacks':
        changedep: changedep
        propchange: propchange

    @_computed[prop_name] = prop_spec

    # bind propchange callback to change dep event
    @listenTo(this, "changedep:#{prop_name}", prop_spec['callbacks']['propchange'])

    return prop_spec

  set: (key, value, options) ->
    logger.warn("HasProps.set('prop_name', value) is deprecated, use HasProps.prop_name = value instead")
    return @setv(key, value, options)

  get: (prop_name) ->
    logger.warn("HasProps.get('prop_name') is deprecated, use HasProps.prop_name instead")
    return @getv(prop_name)

  getv: (prop_name) ->
    if not @props[prop_name]?
      throw new Error("property #{@type}.#{prop_name} wasn't declared")
    else
      return super(prop_name)

  _get_computed: (prop_name) ->
    prop_spec = @_computed[prop_name]
    if not prop_spec?
      throw new Error("computed property #{@type}.#{prop_name} wasn't declared")
    if prop_spec.use_cache and prop_spec.cache
      return prop_spec.cache
    else
      getter = prop_spec.getter
      computed = getter.apply(this, [prop_name])
      if prop_spec.use_cache
        prop_spec.cache = computed
      return computed

  ref: () -> refs.create_ref(@)

  # we only keep the subtype so we match Python;
  # only Python cares about this
  set_subtype: (subtype) ->
    @_subtype = subtype

  attribute_is_serializable: (attr) ->
    prop = @props[attr]
    if not prop?
      throw new Error("#{@type}.attribute_is_serializable('#{attr}'): #{attr} wasn't declared")
    else
      return not prop.internal

  # dict of attributes that should be serialized to the server. We
  # sometimes stick things in attributes that aren't part of the
  # Document's models, subtypes that do that have to remove their
  # extra attributes here.
  serializable_attributes: () ->
    attrs = {}
    for name, value of @attributes
      if @attribute_is_serializable(name)
        attrs[name] = value
    return attrs

  @_value_to_json: (key, value, optional_parent_object) ->
    if value instanceof HasProps
      value.ref()
    else if isArray(value)
      ref_array = []
      for v, i in value
        ref_array.push(HasProps._value_to_json(i, v, value))
      ref_array
    else if isObject(value)
      ref_obj = {}
      for own subkey of value
        ref_obj[subkey] = HasProps._value_to_json(subkey, value[subkey], value)
      ref_obj
    else
      value

  # Convert attributes to "shallow" JSON (values which are themselves models
  # are included as just references)
  # TODO (havocp) can this just be toJSON (from Backbone / JSON.stingify?)
  # backbone will have implemented a toJSON already that we may need to override
  # optional value_to_json is for test to override with a "deep" version to replace the
  # standard "shallow" HasProps._value_to_json
  attributes_as_json: (include_defaults=true, value_to_json=HasProps._value_to_json) ->
    attrs = {}
    for own key, value of @serializable_attributes()
      if include_defaults
        attrs[key] = value
      else if key of @_set_after_defaults
        attrs[key] = value
    value_to_json("attributes", attrs, @)

  # this is like _value_record_references but expects to find refs
  # instead of models, and takes a doc to look up the refs in
  @_json_record_references: (doc, v, result, recurse) ->
    if v is null
      ;
    else if refs.is_ref(v)
      if v.id not of result
        model = doc.get_model_by_id(v.id)
        HasProps._value_record_references(model, result, recurse)
    else if isArray(v)
      for elem in v
        HasProps._json_record_references(doc, elem, result, recurse)
    else if isObject(v)
      for own k, elem of v
        HasProps._json_record_references(doc, elem, result, recurse)

  # add all references from 'v' to 'result', if recurse
  # is true then descend into refs, if false only
  # descend into non-refs
  @_value_record_references: (v, result, recurse) ->
    if v is null
      ;
    else if v instanceof HasProps
      if v.id not of result
        result[v.id] = v
        if recurse
          immediate = v._immediate_references()
          for obj in immediate
            HasProps._value_record_references(obj, result, true) # true=recurse
    else if v.buffer instanceof ArrayBuffer
    else if isArray(v)
      for elem in v
        HasProps._value_record_references(elem, result, recurse)
    else if isObject(v)
      for own k, elem of v
        HasProps._value_record_references(elem, result, recurse)

  # Get models that are immediately referenced by our properties
  # (do not recurse, do not include ourselves)
  _immediate_references: () ->
    result = {}
    attrs = @serializable_attributes()
    for key of attrs
      value = attrs[key]
      HasProps._value_record_references(value, result, false) # false = no recurse

    values(result)

  references: () ->
    references = {}
    HasProps._value_record_references(this, references, true)
    return values(references)

  attach_document: (doc) ->
    # This should only be called by the Document implementation to set the document field
    if @document != null and @document != doc
      throw new Error("models must be owned by only a single document")

    @document = doc

    # XXXXXXX not sure about the things below yet

    # TODO (bev) is there are way to get rid of this?
    for name, prop of @properties
      prop.update()

    if @_doc_attached?
      @_doc_attached()

  detach_document: () ->
    # This should only be called by the Document implementation to unset the document field
    @document = null

  _tell_document_about_change: (attr, old, new_, options) ->
    if not @attribute_is_serializable(attr)
      return

    if @document != null
      new_refs = {}
      HasProps._value_record_references(new_, new_refs, false)

      old_refs = {}
      HasProps._value_record_references(old, old_refs, false)

      need_invalidate = false
      for new_id, new_ref of new_refs
        if new_id not of old_refs
          need_invalidate = true
          break

      if not need_invalidate
        for old_id, old_ref of old_refs
          if old_id not of new_refs
            need_invalidate = true
            break

      if need_invalidate
        @document._invalidate_all_models()

      @document._notify_change(@, attr, old, new_, options)

  materialize_dataspecs: (source) ->
    # Note: this should be moved to a function separate from HasProps
    data = {}
    for name, prop of @properties
      if not prop.dataspec
        continue
      # this skips optional properties like radius for circles
      if (prop.optional || false) and prop.spec.value == null and (name not of @_set_after_defaults)
        continue
      data["_#{name}"] = prop.array(source)
      # the shapes are indexed by the column name, but when we materialize the dataspec, we should
      # store under the canonical field name, e.g. _image_shape, even if the column name is "foo"
      if prop.spec.field? and prop.spec.field of source._shapes
        data["_#{name}_shape"] = source._shapes[prop.spec.field]
      if prop instanceof p.Distance
        data["max_#{name}"] = max(data["_#{name}"])
    return data
