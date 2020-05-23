require_relative 'layer/query'
require_relative 'layer/map'

module NSWTopo
  module ArcGIS
    class Layer
      EXCLUDE = %w[esriFieldTypeGeometry esriFieldTypeDate esriFieldTypeBlob esriFieldTypeRaster esriFieldTypeXML].to_set

      def initialize(service, id: nil, layer: nil, fields: nil, launder: nil, truncate: nil, decode: nil, mixed: true, **options)
        raise "no ArcGIS layer name or url provided" unless layer || id
        @id, @name = service["layers"].find do |info|
          layer ? String(layer) == info["name"] : Integer(id) == info["id"]
        end&.values_at("id", "name")
        raise "ArcGIS layer does not exist: #{layer || id}" unless @id

        @service = service
        @layer = get_json @id
        raise "ArcGIS layer is not a feature layer: #{@name}" unless @layer["type"] == "Feature Layer"

        @geometry_type = @layer["geometryType"]

        fields ||= @layer["fields"].reject do |field|
          EXCLUDE === field["type"]
        end.map do |field|
          field["name"]
        end

        @fields = fields.map do |name|
          @layer["fields"].find(-> { raise "invalid field name: #{name}" }) do |field|
            field.values_at("alias", "name").include? name
          end.fetch("name")
        end.uniq

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
        end

        coded_values = @layer["fields"].map do |field|
          [field["name"], field.dig("domain", "codedValues")]
        end.select(&:last).map do |name, pairs|
          values = pairs.map do |pair|
            pair.values_at "code", "name"
          end.to_h
          [name, values]
        end.to_h

        rename = @fields.map do |name|
          next name, launder ? name.downcase.gsub(/[^\w]+/, ?_) : name
        end.map do |name, substitute|
          next name, truncate ? substitute.slice(0...truncate) : substitute
        end.partition do |name, substitute|
          name == substitute
        end.inject(&:+).inject(Hash[]) do |lookup, (name, substitute)|
          suffix, index, candidate = "_2", 3, substitute
          while lookup.key? candidate
            suffix, index, candidate = "_#{index}", index + 1, (truncate ? substitute.slice(0, truncate - suffix.length) : substitute) + suffix
            raise "can't individualise field name: #{name}" if truncate && suffix.length >= truncate
          end
          lookup.merge candidate => name
        end.invert

        @transform = lambda do |feature|
          feature.properties.map do |name, value|
            next rename[name], case
            when %w[null Null NULL <null> <Null> <NULL>].include?(value)
              nil
            when !decode
              value
            when @type_field == name
              @type_values[value]
            when lookup = @subtype_values&.dig(feature.properties[@type_field], name)
              lookup[value]
            when lookup = coded_values.dig(name)
              lookup[value]
            else value
            end
          end.to_h.tap do |properties|
            feature.properties.replace properties
          end
        end

        case @layer["capabilities"]
        when /Query/ then extend Query
        when /Map/   then extend Map
        else raise "ArcGIS layer does not include Query or Map capability: #{@name}"
        end.prepare(**options)
      end

      extend Forwardable
      delegate %i[get get_json projection] => :@service
      attr_reader :count

      def join_clauses(*clauses)
        "(" << clauses.join(") AND (") << ")" if clauses.any?
      end

      def paged(per_page: nil)
        per_page = [*per_page, *@layer["maxRecordCount"], 500].min
        Enumerator::Lazy.new pages(per_page: per_page) do |yielder, page|
          page.each(&@transform)
          yielder << page
        end
      end

      def features(**options, &block)
        paged(**options).inject do |collection, page|
          yield collection.count, self.count if block_given?
          collection.merge! page
        end
      end
    end
  end
end
