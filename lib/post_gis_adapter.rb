require 'active_record'
require 'geo_ruby'
require 'spatial_adapter_common.rb'

include GeoRuby::SimpleFeatures

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.class_eval do

  include SpatialAdapter

  alias :original_native_database_types :native_database_types
  def native_database_types
    original_native_database_types.merge!(geometry_data_types)
  end

  alias :original_quote :quote
  #Redefines the quote method to add behaviour for when a Geometry is encountered
  def quote(value, column = nil)
    if value.kind_of?(GeoRuby::SimpleFeatures::Geometry)
      "'#{value.as_hex_ewkb}'"
    else
      original_quote(value,column)
    end
  end

  def create_table(name, options = {})
    table_definition = PostgreSQLTableDefinition.new(self)
    table_definition.primary_key(options[:primary_key] || "id") unless options[:id] == false
    
    yield table_definition
    
    if options[:force]
      drop_table(name) rescue nil
    end
    
    create_sql = "CREATE#{' TEMPORARY' if options[:temporary]} TABLE "
    create_sql << "#{name} ("
    create_sql << table_definition.to_sql
    create_sql << ") #{options[:options]}"
    execute create_sql
    
    #added to create the geometric columns identified during the table definition
    unless table_definition.geom_columns.nil?
      table_definition.geom_columns.each do |geom_column|
        execute geom_column.to_sql(name)
      end
    end
  end
  
  alias :original_remove_column :remove_column
  def remove_column(table_name,column_name)
    columns(table_name).each do |col|
      if col.name == column_name 
        #check if the column is geometric
        unless geometry_data_types[col.type].nil?
          execute "SELECT DropGeometryColumn('#{table_name}','#{column_name}')"
        else
          original_remove_column(table_name,column_name)
        end
      end
    end
  end
  
  alias :original_add_column :add_column
  def add_column(table_name, column_name, type, options = {})
    unless geometry_data_types[type].nil?
      geom_column = PostgreSQLColumnDefinition.new(self, column_name, type).with_spatial_info
      geom_column.null = options[:null]
      geom_column.srid = options[:srid] || -1
      geom_column.with_z = options[:with_z] || false 
      geom_column.with_m = options[:with_m] || false
      
      execute geom_column.to_sql(table_name)
    else
      original_add_column(table_name,column_name,type,options)
    end
  end
  
  
  
  #Adds a GIST spatial index to a column. Its name will be <table_name>_<column_name>_spatial_index unless the key :name is present in the options hash, in which case its value is taken as the name of the index.
  def add_index(table_name,column_name,options = {})
    index_name = options[:name] ||"#{table_name}_#{Array(column_name).first}_index"
    if options[:spatial]
      if column_name.is_a?(Array) and column_name.length > 1
        #one by one or error : Should raise exception instead? ; use default name even if name passed as argument
        Array(column_name).each do |col|
          execute "CREATE INDEX #{table_name}_#{col}_index ON #{table_name} USING GIST (#{col} GIST_GEOMETRY_OPS)"
        end
      else
        col = Array(column_name)[0]
        execute "CREATE INDEX #{index_name} ON #{table_name} USING GIST (#{col} GIST_GEOMETRY_OPS)"
      end
    else
      index_type = options[:unique] ? "UNIQUE" : ""
      #all together
      execute "CREATE #{index_type} INDEX #{index_name} ON #{table_name} (#{Array(column_name).join(", ")})"
    end
  end
  
      
  def indexes(table_name, name = nil) #:nodoc:
    result = query(<<-SQL, name)
          SELECT i.relname, d.indisunique, a.attname , am.amname
            FROM pg_class t, pg_class i, pg_index d, pg_attribute a, pg_am am
           WHERE i.relkind = 'i'
             AND d.indexrelid = i.oid
             AND d.indisprimary = 'f'
             AND t.oid = d.indrelid
             AND i.relam = am.oid
             AND t.relname = '#{table_name}'
             AND a.attrelid = t.oid
             AND ( d.indkey[0]=a.attnum OR d.indkey[1]=a.attnum
                OR d.indkey[2]=a.attnum OR d.indkey[3]=a.attnum
                OR d.indkey[4]=a.attnum OR d.indkey[5]=a.attnum
                OR d.indkey[6]=a.attnum OR d.indkey[7]=a.attnum
                OR d.indkey[8]=a.attnum OR d.indkey[9]=a.attnum )
          ORDER BY i.relname
        SQL

    current_index = nil
    indexes = []
    
    result.each do |row|
      if current_index != row[0]
        indexes << ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, row[0], row[1] == "t", row[3] == "gist" ,[]) #index type gist indicates a spatial index (probably not totally true but let's simplify!)
        current_index = row[0]
      end
      
      indexes.last.columns << row[2]
    end
    
    indexes
  end
      
  def columns(table_name, name = nil) #:nodoc:
    spatial_info = column_spatial_info(table_name)
    
    column_definitions(table_name).collect do |name, type, default, notnull|
      if type =~ /geometry/i and spatial_info[name]
        SpatialPostgreSQLColumn.new(name,default_value(default),raw_geom_info.type,notnull == "f",*spatial_info[name]))
      else
        Column.new(name, default_value(default), translate_field_type(type),notnull == "f")
      end
    end
  end
      
  private
         
  def column_spatial_info(table_name)
    constr = query <<-end_sql
    SELECT pg_get_constraintdef(oid) 
    FROM pg_constraint
    WHERE conrelid = '#{table_name}'::regclass
    AND contype = 'c'
    end_sql

    RawGeomInfo = Struct.new(:type,:srid,:dimension,:with_m)
    raw_geom_infos = {}
    constr.each do |constr_def_a|
      constr_def = constr_def_a[0] #only 1 column in the result
      if constr_def =~ /geometrytype\(([^)]+)\)\s*=\s*'([^']+)'/i
        column_name,type = $1,$2
        if type[-1] == ?M
          with_m = true
          type.chop!
        else
          with_m = false
        end
        raw_geom_info = raw_geom_infos[column_name] || RawGeomInfo.new
        raw_geom_info.type = type
        raw_geom_info.with_m = with_m
        raw_geom_infos[column_name] = raw_geom_info
      elsif constr_def =~ /ndims\(([^)]+)\)\s*=\s*(\d+)/i
        column_name,dimension = $1,$2
        raw_geom_info = raw_geom_infos[column_name] || RawGeomInfo.new
        raw_geom_info.dimension = dimension.to_i
        raw_geom_infos[column_name] = raw_geom_info
      elsif constr_def =~ /srid\(([^)]+)\)\s*=\s*(-?\d+)/i
        column_name,srid = $1,$2
        raw_geom_info = raw_geom_infos[column_name] || RawGeomInfo.new
        raw_geom_info.srid = srid
        raw_geom_infos[column_name] = raw_geom_info
      end #if constr_def
    end #constr.each

    spatial_infos = {}
    raw_geom_infos.each_key do |column_name|
      raw_geom_info = raw_geom_infos[column_name]
      if raw_geom_info.dimension == 4
        with_m= true
        with_z=true
      elsif raw_geom_info.dimension == 3
        if raw_geom_info.with_m
          with_z=false
          with_m=true 
        else
          with_z=true
          with_m=false
        end
      else
        with_z = false
        with_m = false
      end
      spatial_infos[column_name] = [raw_geom_info.srid,with_z,with_m]
    end

    spatial_infos

  end
  
end


module ActiveRecord
  module ConnectionAdapters
    class PostgreSQLTableDefinition < TableDefinition
      attr_reader :geom_columns
      
      def column(name, type, options = {})
        unless @base.geometry_data_types[type].nil?
          geom_column = PostgreSQLColumnDefinition.new(@base,name, type).with_spatial_info
          geom_column.null = options[:null]
          geom_column.srid = options[:srid] || -1
          geom_column.with_z = options[:with_z] || false 
          geom_column.with_m = options[:with_m] || false
         
          @geom_columns = [] if @geom_columns.nil?
          @geom_columns << geom_column          
        else
          super(name,type,options)
        end
      end
    end

    class PostgreSQLColumnDefinition < ColumnDefinition
      attr_accessor :srid, :with_z,:with_m
      attr_reader :spatial

      def with_spatial_info(srid=-1,with_z=false,with_m=false)
        @spatial=true
        @srid=srid
        @with_z=with_z
        @with_m=with_m
      end
      
      def to_sql
        if @spatial
          type_sql = type_to_sql(type.to_sym)
          type_sql += "M" if with_m and !with_z
          if with_m and with_z
            dimension = 4 
          elsif with_m or with_z
            dimension = 3
          else
            dimension = 2
          end
          column_sql = "SELECT AddGeometryColumn('#{@base.name}','#{name}',#{srid},'#{type_sql}',#{dimension})"
          column_sql += ";ALTER TABLE #{@base.name} ALTER #{column_name} SET NOT NULL" if null == false
          column_sql
        else
          super
        end
      end
  
  
      private
      def type_to_sql(name, limit=nil)
        base.type_to_sql(name, limit) rescue name
      end   
      
    end

  end
end

#Would prefer creation of a PostgreSQLColumn type instead but I would need to reimplement methods where Column objects are instantiated so I leave it like this
module ActiveRecord
  module ConnectionAdapters
    class SpatialPostgreSQLColumn < Column

      include SpatialColumn
      
      #Transforms a string to a geometry. PostGIS returns a HewEWKB string.
      def self.string_to_geometry(string)
        return string unless string.is_a?(String)
        begin
          GeoRuby::SimpleFeatures::Geometry.from_hexewkb(string)
        rescue Exception => exception
          nil
        end
      end
    end
  end
end
