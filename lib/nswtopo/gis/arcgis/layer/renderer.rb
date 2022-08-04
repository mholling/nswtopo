module NSWTopo
  module ArcGIS
    module Renderer
      TooManyFieldsError = Class.new RuntimeError
      NoGeometryError = Class.new RuntimeError

      def classify(*fields, where: @where)
        raise TooManyFieldsError unless fields.size <= 3
        raise NoGeometryError, "ArcGIS layer does not support spatial filtering: #{@name}" if @geometry

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
            when type == "esriFieldTypeDate"
              begin
                Time.strptime(value, "%m/%d/%Y %l:%M:%S %p").to_i * 1000
              rescue ArgumentError
              end
            end
          rescue ArgumentError
            raise "could not interpret #{value.inspect} as #{type}"
          end.then do |values|
            fields.zip values
          end.to_h
        end.zip counts
      end
    end
  end
end
