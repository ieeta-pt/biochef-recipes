import os
import yaml
import subprocess
import shutil

BIOWASM_DIR = "biowasm"
BUILD_DIR = "build"
BASE_DIR = os.getcwd()

def compile_biowasm(tool_name):
    os.chdir(BIOWASM_DIR)
    subprocess.run(["python", "./bin/compile.py", "--tools", tool_name])
    os.chdir("..")

    if os.path.isdir(f"{BIOWASM_DIR}/{BUILD_DIR}"):
        shutil.copytree(f"{BIOWASM_DIR}/{BUILD_DIR}/{tool_name}", f"{BUILD_DIR}/{tool_name}", dirs_exist_ok=True)
        shutil.rmtree(f"{BIOWASM_DIR}/{BUILD_DIR}")
        return True
    
    return False

def compile_emscripten(tool_name, version, settings, source):
    buildsystem = settings.get('buildsystem')
    
    if buildsystem == "make":
        repo_url, tag, commit = source
        
        repo_dir = os.path.basename(repo_url).replace(".git", "") + "_clone"
        
        if os.path.isdir(repo_dir):
            shutil.rmtree(repo_dir)
        subprocess.run(["git", "clone", repo_url, repo_dir], check=True)
        
        os.chdir(repo_dir)
        
        if tag:
            subprocess.run(["git", "checkout", "tags/" + tag], check=True)
        elif commit:
            subprocess.run(["git", "checkout", commit], check=True)

        full_repo_dir = os.getcwd()
        workdir = settings.get("workDir", ".")
        os.chdir(workdir)

        makefile_path = "Makefile"
        backup_file = f"Makefile.bak"
        shutil.copy(makefile_path, backup_file)

        commands = settings.get("commands", [])
        for command in commands:
            subprocess.run(command, shell=True, check=True)

        env = os.environ.copy()
        env["EM_FLAGS"] = "-s USE_ZLIB=1 -s INVOKE_RUN=0 -s FORCE_FILESYSTEM=1 -s EXPORTED_RUNTIME_METHODS=['callMain','FS','PROXYFS','WORKERFS'] -s MODULARIZE=1 -s ENVIRONMENT=['web','worker'] -s ALLOW_MEMORY_GROWTH=1 -s EXIT_RUNTIME=1 -lworkerfs.js -lproxyfs.js"

        try:
            subprocess.run(f"emmake make {" ".join(settings["env"])}", shell=True, check=True)
            output_dir = f"{full_repo_dir}/{settings['outputDir']}"
            dest_dir = f"{BASE_DIR}/{BUILD_DIR}/{tool_name}/{version}/"

            # Ensure the destination directory exists
            os.makedirs(dest_dir, exist_ok=True)
            
            # Only copy .js and .wasm files
            for root, _, files in os.walk(output_dir):
                for file in files:
                    if file.endswith(".js") or file.endswith(".wasm"):
                        src_file = os.path.join(root, file)
                        dest_file = os.path.join(dest_dir, file)
                        shutil.copy(src_file, dest_file)

            return True
        except subprocess.CalledProcessError as e:
            print(f"Error running make: {e}")
            return False
        finally:
            # Restore the original Makefile from the backup
            shutil.copy(backup_file, makefile_path)
            shutil.rmtree(full_repo_dir)

    return False
    
if __name__=="__main__":
    try:
        if os.path.isdir(BIOWASM_DIR):
            shutil.rmtree(BIOWASM_DIR)
        subprocess.run(["git", "clone", "https://github.com/biowasm/biowasm", BIOWASM_DIR], check=True)
    except:
        print("Error cloning biowasm repository")
        exit(-1)

    for dir_name in os.listdir('.'):
        if dir_name.startswith('.'): continue # ignore hidden
        if not os.path.isdir(dir_name): continue # ignore files
        
        yaml_file_path = os.path.join(dir_name, 'biochef.yaml')
        if not os.path.isfile(yaml_file_path): continue

        with open(yaml_file_path, 'r') as file:
            data = yaml.safe_load(file)
            wasm_settings = data['build']['wasm']
            wasm_strategy = wasm_settings['strategy']
            if not wasm_strategy: continue

            tool_name = data["build"]["wasm"].get("biowasm",{}).get("package", "")
            if not tool_name:
                tool_name = data["name"]
            
            print(f"Attempting to compile {tool_name}")
            if wasm_strategy == "auto":
                if not compile_biowasm(tool_name):
                    print("Could not compile with biowasm, trying with emscripten...")
                    source = (data["source"]["repo"],data["source"]["tag"],data["source"]["commit"])
                    if not compile_emscripten(tool_name, data["version"].split("-")[0],wasm_settings['emscripten'], source):
                        print("Could not compile with emscripten.")

    os.chdir(BASE_DIR)
    shutil.rmtree(BIOWASM_DIR)