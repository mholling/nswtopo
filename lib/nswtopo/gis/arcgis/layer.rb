require_relative 'layer/query'
require_relative 'layer/map'

module NSWTopo
  module ArcGIS
    class Layer
      FIELD_TYPES = %W[esriFieldTypeOID esriFieldTypeInteger esriFieldTypeSmallInteger esriFieldTypeDouble esriFieldTypeSingle esriFieldTypeString esriFieldTypeGUID].to_set
      NoLayerError = Class.new RuntimeError
      TooManyFieldsError = Class.new RuntimeError

      def initialize(service, id: nil, layer: nil, where: nil, fields: nil, launder: nil, truncate: nil, decode: nil, mixed: true, geometry: nil, unique: nil)
        raise NoLayerError, "no ArcGIS layer name or url provided" unless layer || id
        @id, @name = service["layers"].find do |info|
          layer ? String(layer) == info["name"] : Integer(id) == info["id"]
        end&.values_at("id", "name")
        raise "ArcGIS layer does not exist: #{layer || id}" unless @id

        @service, @where, @decode, @mixed, @geometry, @unique = service, where, decode, mixed, geometry, unique

        @layer = get_json @id
        raise "ArcGIS layer is not a feature layer: #{@name}" unless @layer["type"] == "Feature Layer"

        @geometry_type = @layer["geometryType"]

        @fields = fields&.map do |name|
          @layer["fields"].find(-> { raise "invalid field name: #{name}" }) do |field|
            field.values_at("alias", "name").include? name
          end.fetch("name")
        end

        [[%w[typeIdField], %w[subtypeField subtypeFieldName]], %w[types subtypes], %w[id code]].transpose.map do |name_keys, lookup_key, value_key|
          next @layer.values_at(*name_keys).compact.reject(&:empty?).first, @layer[lookup_key], value_key
        end.find do |name_or_alias, lookup, value_key|
          name_or_alias && lookup&.any?
        end&.tap do |name_or_alias, lookup, value_key|
          @type_field = @layer["fields"].find do |field|
            field.values_at("alias", "name").compact.include? name_or_alias
          end&.fetch("name")

          @type_values = lookup.map do |type|
            type.values_at value_key, "name"
          end.to_h

          @subtype_values = lookup.map do |type|
            type.values_at value_key, "domains"
          end.map do |code, domains|
            coded_values = domains.map do |name, domain|
              [name, domain["codedValues"]]
            end.select(&:last).map do |name, pairs|
              values = pairs.map do |pair|
                pair.values_at "code", "name"
              end.to_h
              [name, values]
            end.to_h
            [code, coded_values]
          end.to_h

          @subtype_fields = @subtype_values.values.flat_map(&:keys).uniq
        end

        coded_values = @layer["fields"].map do |field|
          [field["name"], field.dig("domain", "codedValues")]
        end.select(&:last).map do |name, pairs|
          values = pairs.map do |pair|
            pair.values_at "code", "name"
          end.to_h
          [name, values]
        end.to_h

        @rename = @layer["fields"].map do |field|
          field["name"]
        end.map do |name|
          next name, launder ? name.downcase.gsub(/[^\w]+/, ?_) : name
        end.map do |name, substitute|
          next name, truncate ? substitute.slice(0...truncate) : substitute
        end.sort_by do |name, substitute|
          [@fields&.include?(name) ? 0 : 1, substitute == name ? 0 : 1]
        end.inject(Hash[]) do |lookup, (name, substitute)|
          suffix, index, candidate = "_2", 3, substitute
          while lookup.key? candidate
            suffix, index, candidate = "_#{index}", index + 1, (truncate ? substitute.slice(0, truncate - suffix.length) : substitute) + suffix
            raise "can't individualise field name: #{name}" if truncate && suffix.length >= truncate
          end
          lookup.merge candidate => name
        end.invert.to_proc

        @revalue = lambda do |name, value, properties|
          case
          when %w[null Null NULL <null> <Null> <NULL>].include?(value)
            nil
          when !decode
            value
          when @type_field == name
            @type_values[value]
          when lookup = @subtype_values&.dig(properties[@type_field], name)
            lookup[value]
          when lookup = coded_values.dig(name)
            lookup[value]
          else value
          end
        end

        case @layer["capabilities"]
        when /Query/ then extend Query
        when /Map/   then extend Map
        else raise "ArcGIS layer does not include Query or Map capability: #{@name}"
        end
      end

      extend Forwardable
      delegate %i[get get_json projection] => :@service
      attr_reader :count

      def extra_field
        case
        when !@decode || !@type_field || !@fields
        when @fields.include?(@type_field)
        when (@subtype_fields & @fields).any? then @type_field
        end
      end

      def decode(attributes)
        attributes.map do |name, value|
          [name, @revalue[name, value, attributes]]
        end.to_h.slice(*@fields).yield_self do |decoded|
          attributes.replace decoded
        end
      end

      def transform(feature)
        decode(feature.properties).transform_keys!(&@rename)
      end

      def paged(per_page: nil)
        per_page = [*per_page, *@layer["maxRecordCount"], 500].min
        Enumerator::Lazy.new pages(per_page) do |yielder, page|
          page.each(&method(:transform))
          yielder << page
        end
      end

      def features(**options, &block)
        paged(**options).inject do |collection, page|
          yield collection.count, self.count if block_given?
          collection.merge! page
        end
      end

      def join_clauses(*clauses)
        "(" << clauses.join(") AND (") << ")" if clauses.any?
      end

      def classify(*fields, where: nil)
        raise TooManyFieldsError unless fields.size <= 3
        types = fields.map do |name|
          @layer["fields"].find do |field|
            field["name"] == name
          end&.fetch("type")
        end

        counts, values = 2.times do |repeat|
          counts, values = %w[| ~ ^ #].find do |delimiter|
            classification_def = { type: "uniqueValueDef", uniqueValueFields: fields.take(repeat) + fields, fieldDelimiter: delimiter }
            unique_values = get_json("#{@id}/generateRenderer", where: join_clauses(*where), classificationDef: classification_def.to_json).fetch("uniqueValueInfos")

            values = unique_values.map do |info|
              info["value"].split(delimiter).map(&:strip)
            end
            next unless values.all? do |values|
              values.length == fields.length + repeat
            end
            repeat.times { values.each(&:shift) }
            counts = unique_values.map do |info|
              info["count"]
            end
            break counts, values
          end
          raise "couldn't delimit values" unless values
          next if 0 == repeat && fields.one? && (counts.all?(1) || counts.all?(0))
          break counts, values
        end

        values.map do |values|
          values.zip(types).map do |value, type|
            case
            when value == "<Null>" then nil
            when value == "" then nil
            when type == "esriFieldTypeOID" then Integer(value)
            when type == "esriFieldTypeInteger" then Integer(value)
            when type == "esriFieldTypeSmallInteger" then Integer(value)
            when type == "esriFieldTypeDouble" then Float(value)
            when type == "esriFieldTypeSingle" then Float(value)
            when type == "esriFieldTypeString" then String(value)
            when type == "esriFieldTypeGUID" then String(value)
            when type == "esriFieldTypeDate" then String(value)
            end
          rescue ArgumentError
            raise "could not interpret #{value.inspect} as #{type}"
          end.yield_self do |values|
            fields.zip values
          end.to_h
        end.zip counts
      end

      def counts
        classify(*@fields, *extra_field, where: @where).each do |attributes, count|
          decode attributes
        end.group_by(&:first).map do |attributes, attributes_counts|
          [attributes, attributes_counts.sum(&:last)]
        end
      end

      def info
        @layer.slice("name", "id").tap do |info|
          info["geometry"] = case @geometry_type
          when "esriGeometryPoint" then "Point"
          when "esriGeometryMultipoint" then "Multipoint"
          when "esriGeometryPolyline" then "LineString"
          when "esriGeometryPolygon" then "Polygon"
          else @geometry_type.delete_prefix("esriGeometry")
          end
          info["fields"] = @layer["fields"].map do |field|
            [field["name"], field["type"].delete_prefix("esriFieldType")]
          end.sort_by(&:first).to_h if @layer["fields"]&.any?
        end
      end
    end
  end
end
