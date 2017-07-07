configfile: "config.yaml"

samples = config["samples"]


rule all:
    input:
        fwd = expand("test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz", sample=samples),
        rev = expand("test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz", sample=samples),
        humann2 = "test_out/humann2/genefamilies.txt"
    run:
        print('Fooing foo:')


rule qc_atropos:
    """
    Does adapter trimming and read QC with Atropos
    """
    input:
        forward = "test_data/{sample}.R1.fastq.gz",
        reverse = "test_data/{sample}.R2.fastq.gz"
    output:
        forward = "test_out/trimmed/{sample}.trimmed.R1.fastq.gz",
        reverse = "test_out/trimmed/{sample}.trimmed.R2.fastq.gz"
    threads:
        2
    conda:
        "envs/shotgun-qc.yaml"
    params:
        atropos = config['params']['atropos']
    log:
        "test_out/logs/qc_atropos.sample=[{sample}].log"
    shell:
        "atropos --threads {threads} {params.atropos} --report-file {log} --report-formats txt -o {output.forward} -p {output.reverse} -pe1 {input.forward} -pe2 {input.reverse}"


rule qc_filter:
    """
    Performs host read filtering on paired end data using Bowtie and Samtools/
    BEDtools. Takes the four output files generated by Trimmomatic. 

    Also requires an indexed reference (path specified in config). 

    First, uses Bowtie output piped through Samtools to only retain read pairs
    that are never mapped (either concordantly or just singly) to the indexed
    reference genome. Fastqs from this are gzipped into matched forward and 
    reverse pairs. 

    Unpaired forward and reverse reads are simply run through Bowtie and
    non-mapping gzipped reads output.

    All piped output first written to localscratch to avoid tying up filesystem.
    """
    input:
        forward = "test_out/trimmed/{sample}.trimmed.R1.fastq.gz",
        reverse = "test_out/trimmed/{sample}.trimmed.R2.fastq.gz"
    output:
        forward = "test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz",
        reverse = "test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz"
    params:
        filter = config['params']['filter']
    threads:
        2
    conda:
        "envs/shotgun-qc.yaml"
    log:
        bowtie = "test_out/logs/qc_filter.bowtie.sample=[{sample}].log",
        other = "test_out/logs/qc_filter.other.sample=[{sample}].log"
    shell:
        """
        bowtie2 -p {threads} {params.filter} -1 {input.forward} -2 {input.reverse} 2> {log.bowtie} | \
        samtools view -f 12 -F 256 2> {log.other} | \
        samtools sort -@ {threads} -n 2> {log.other} | \
        samtools view -bS 2> {log.other} | \
        bedtools bamtofastq -i - -fq {wildcards.sample}.R1.trimmed.filtered.fastq -fq2 {wildcards.sample}.R2.trimmed.filtered.fastq 2> {log.other}

        gzip -c {wildcards.sample}.R1.trimmed.filtered.fastq > {output.forward}
        gzip -c {wildcards.sample}.R2.trimmed.filtered.fastq > {output.reverse}

        rm {wildcards.sample}.R1.trimmed.filtered.fastq
        rm {wildcards.sample}.R2.trimmed.filtered.fastq
        """


rule function_humann2:
    """
    Runs HUMAnN2 pipeline using general defaults.

    Other HUMAnN2 parameters can be specified as a quoted string in 
    PARAMS: HUMANN2: OTHER. 

    Going to do just R1 reads for now. Because of how I've split PE vs SE
    processing and naming, still will need to make a separate rule for PE. 
    """
    input:
        forward = "test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz",
        reverse = "test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz"
    output:
        genefamilies = temp("test_out/humann2/{sample}/{sample}_genefamilies.txt"),
        pathcoverage = temp("test_out/humann2/{sample}/{sample}_pathcoverage.txt"),
        pathabundance = temp("test_out/humann2/{sample}/{sample}_pathabundance.txt")
    params:
        humann2 = config['params']['humann2'],
        metaphlan2 = config['params']['metaphlan2']
    threads:
        8
    conda:
        "envs/shotgun-humann2.yaml"
    log:
        "test_out/logs/function_humann2_{sample}.log"
    shell:
        """
        mkdir -p test_out/humann2/{wildcards.sample}/temp
        cat {input.forward} {input.reverse} > test_out/humann2/{wildcards.sample}/temp/input.fastq.gz

        humann2 --input test_out/humann2/{wildcards.sample}/temp/input.fastq.gz \
        --output test_out/humann2/{wildcards.sample}/temp \
        --output-basename {wildcards.sample} \
        --o-log {log} \
        --threads {threads} \
        --metaphlan {params.metaphlan2} \
        {params.humann2} 2> {log} 1>&2
        """


rule function_humann2_combine_tables:
    """
    Combines the per-sample normalized tables into a single run-wide table. 

    Because HUMAnN2 takes a directory as input, first copies all the individual
    tables generated in this run to a temp directory and runs on that.
    """
    input:
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_genefamilies.txt",
               sample=samples),
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_pathcoverage.txt",
               sample=samples),
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_pathabundance.txt",
               sample=samples)
    output:
        genefamilies = "test_out/humann2/genefamilies.txt",
        pathcoverage = "test_out/humann2/pathcoverage.txt",
        pathabundance = "test_out/humann2/pathabundance.txt",
        genefamilies_cpm = "test_out/humann2/genefamilies_cpm.txt",
        pathcoverage_relab = "test_out/humann2/pathcoverage_relab.txt",
        pathabundance_relab = "test_out/humann2/pathabundance_relab.txt",
        genefamilies_cpm_strat = "test_out/humann2/genefamilies_cpm_stratified.txt",
        pathcoverage_relab_strat = "test_out/humann2/pathcoverage_relab_stratified.txt",
        pathabundance_relab_strat = "test_out/humann2/pathabundance_relab_stratified.txt",
        genefamilies_cpm_unstrat = "test_out/humann2/genefamilies_cpm_unstratified.txt",
        pathcoverage_relab_unstrat = "test_out/humann2/pathcoverage_relab_unstratified.txt",
        pathabundance_relab_unstrat = "test_out/humann2/pathabundance_relab_unstratified.txt"
    conda:
        "envs/shotgun-humann2.yaml"
    log:
        "test_out/logs/function_humann2_combine_tables.log"
    shell:
        """
          humann2_join_tables --input test_out/humann2/ \
          --search-subdirectories \
          --output test_out/humann2/genefamilies.txt \
          --file_name genefamilies 2> {log} 1>&2

          humann2_join_tables --input test_out/humann2/ \
          --search-subdirectories \
          --output test_out/humann2/pathcoverage.txt \
          --file_name pathcoverage 2>> {log} 1>&2

          humann2_join_tables --input test_out/humann2/ \
          --search-subdirectories \
          --output test_out/humann2/pathabundance.txt \
          --file_name pathabundance 2>> {log} 1>&2


          # normalize
          humann2_renorm_table --input test_out/humann2/genefamilies.txt \
          --output test_out/humann2/genefamilies_cpm.txt \
          --units cpm -s n 2>> {log} 1>&2

          humann2_renorm_table --input test_out/humann2/pathcoverage.txt \
          --output test_out/humann2/pathcoverage_relab.txt \
          --units relab -s n 2>> {log} 1>&2

          humann2_renorm_table --input test_out/humann2/pathabundance.txt \
          --output test_out/humann2/pathabundance_relab.txt \
          --units relab -s n 2>> {log} 1>&2


          # stratify
          humann2_split_stratified_table --input test_out/humann2/genefamilies_cpm.txt \
          --output test_out/humann2 2>> {log} 1>&2

          humann2_split_stratified_table --input test_out/humann2/pathcoverage_relab.txt \
          --output test_out/humann2 2>> {log} 1>&2

          humann2_split_stratified_table --input test_out/humann2/pathabundance_relab.txt \
          --output test_out/humann2 2>> {log} 1>&2
          """

