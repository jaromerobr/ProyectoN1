"""Crea el servidor de Taxiff en Oracle Cloud (gratis, "Always Free"), reintentando
hasta que haya lugar.

Oracle suele responder "Out of capacity" al pedir el servidor gratuito Ampere A1:
este script lo pide cada ~3 minutos (alternando 2 núcleos/12 GB y 1 núcleo/6 GB)
hasta conseguirlo, como mucho 48 h. Solo usa recursos gratuitos.

Necesita:
  - ~/.oci/config: la configuración de la API key (Oracle → Mi perfil → API keys).
  - La llave pública SSH con la que después se entra al servidor (--llave-ssh).

Uso:
  .venv-oci\\Scripts\\python oracle_crear.py --llave-ssh "C:\\...\\ssh-key.key.pub"
  .venv-oci\\Scripts\\python oracle_crear.py --solo-revisar    (prueba la conexión y no crea nada)

Deja lo que pasa en oracle_reintentos.log y, al terminar, la IP en oracle_resultado.json.
"""
import argparse
import ctypes
import json
import random
import sys
import time
from datetime import datetime
from pathlib import Path

import oci

AQUI = Path(__file__).resolve().parent
LOG = AQUI / "oracle_reintentos.log"
RESULTADO = AQUI / "oracle_resultado.json"

NOMBRE = "taxiff-servidor"
FORMA = "VM.Standard.A1.Flex"            # la única gratuita que alcanza para el modelo
TAMANOS = [(2, 12), (1, 6)]              # (núcleos, GB de RAM), dentro de lo gratuito
ESPERA_S = 180
LIMITE_H = 48


def anotar(texto):
    linea = f"{datetime.now():%Y-%m-%d %H:%M:%S} {texto}"
    print(linea, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(linea + "\n")


def no_suspender():
    """Mientras el script corre, Windows no suspende la PC (no cambia ningún ajuste)."""
    if sys.platform == "win32":
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)


def por_nombre(items, nombre):
    return next((i for i in items if i.display_name == nombre and
                 getattr(i, "lifecycle_state", "") not in ("TERMINATED", "TERMINATING")), None)


def preparar_red(red, comp):
    """VCN + salida a internet + subred pública + puertos 22/80/443. Si ya existen, los reutiliza."""
    vcn = por_nombre(red.list_vcns(comp).data, "taxiff-vcn")
    if not vcn:
        anotar("creando la red (VCN)…")
        vcn = red.create_vcn(oci.core.models.CreateVcnDetails(
            compartment_id=comp, display_name="taxiff-vcn", cidr_blocks=["10.0.0.0/16"], dns_label="taxiff")).data
        vcn = oci.wait_until(red, red.get_vcn(vcn.id), "lifecycle_state", "AVAILABLE").data

    igw = por_nombre(red.list_internet_gateways(comp, vcn_id=vcn.id).data, "taxiff-internet")
    if not igw:
        anotar("creando la salida a internet (Internet Gateway)…")
        igw = red.create_internet_gateway(oci.core.models.CreateInternetGatewayDetails(
            compartment_id=comp, vcn_id=vcn.id, is_enabled=True, display_name="taxiff-internet")).data
        igw = oci.wait_until(red, red.get_internet_gateway(igw.id), "lifecycle_state", "AVAILABLE").data

    rt = red.get_route_table(vcn.default_route_table_id).data
    if not any(r.destination == "0.0.0.0/0" for r in rt.route_rules):
        anotar("agregando la ruta a internet…")
        red.update_route_table(rt.id, oci.core.models.UpdateRouteTableDetails(route_rules=rt.route_rules + [
            oci.core.models.RouteRule(destination="0.0.0.0/0", destination_type="CIDR_BLOCK", network_entity_id=igw.id)]))

    sl = red.get_security_list(vcn.default_security_list_id).data
    puertos = {r.tcp_options.destination_port_range.min for r in sl.ingress_security_rules
               if r.protocol == "6" and r.tcp_options and r.tcp_options.destination_port_range}
    nuevas = [oci.core.models.IngressSecurityRule(
        protocol="6", source="0.0.0.0/0", description=desc,
        tcp_options=oci.core.models.TcpOptions(destination_port_range=oci.core.models.PortRange(min=p, max=p)))
        for p, desc in ((22, "ssh"), (80, "http"), (443, "https")) if p not in puertos]
    if nuevas:
        anotar(f"abriendo puertos {[n.tcp_options.destination_port_range.min for n in nuevas]}…")
        red.update_security_list(sl.id, oci.core.models.UpdateSecurityListDetails(
            ingress_security_rules=sl.ingress_security_rules + nuevas, egress_security_rules=sl.egress_security_rules))

    sub = por_nombre(red.list_subnets(comp, vcn_id=vcn.id).data, "taxiff-publica")
    if not sub:
        anotar("creando la subred pública…")
        sub = red.create_subnet(oci.core.models.CreateSubnetDetails(
            compartment_id=comp, vcn_id=vcn.id, cidr_block="10.0.0.0/24", display_name="taxiff-publica",
            dns_label="publica", prohibit_public_ip_on_vnic=False,
            route_table_id=vcn.default_route_table_id, security_list_ids=[vcn.default_security_list_id])).data
        sub = oci.wait_until(red, red.get_subnet(sub.id), "lifecycle_state", "AVAILABLE").data
    return sub


def imagen_ubuntu(comp_cli, comp):
    imgs = comp_cli.list_images(comp, operating_system="Canonical Ubuntu", operating_system_version="24.04",
                                shape=FORMA, sort_by="TIMECREATED", sort_order="DESC").data
    imgs = [i for i in imgs if "Minimal" not in i.display_name]
    if not imgs:
        raise SystemExit("No encontré la imagen de Ubuntu 24.04 para Ampere en esta región.")
    return imgs[0]


def ip_publica(comp_cli, red, comp, inst_id):
    for att in comp_cli.list_vnic_attachments(comp, instance_id=inst_id).data:
        ip = red.get_vnic(att.vnic_id).data.public_ip
        if ip:
            return ip
    return None


def terminar(comp_cli, red, comp, inst):
    inst = oci.wait_until(comp_cli, comp_cli.get_instance(inst.id), "lifecycle_state", "RUNNING",
                          max_wait_seconds=900).data
    ip = ip_publica(comp_cli, red, comp, inst.id)
    datos = {"ip": ip, "usuario": "ubuntu", "instancia": inst.id, "forma": inst.shape,
             "nucleos": inst.shape_config.ocpus, "ram_gb": inst.shape_config.memory_in_gbs,
             "creada": f"{datetime.now():%Y-%m-%d %H:%M:%S}"}
    RESULTADO.write_text(json.dumps(datos, indent=2), encoding="utf-8")
    anotar(f"LISTO: servidor {NOMBRE} en marcha · IP pública {ip} · usuario ubuntu · "
           f"{inst.shape_config.ocpus:g} núcleos / {inst.shape_config.memory_in_gbs:g} GB")
    return datos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--llave-ssh", help="llave pública SSH (.pub) para entrar al servidor")
    ap.add_argument("--solo-revisar", action="store_true", help="prueba la conexión y no crea nada")
    a = ap.parse_args()

    config = oci.config.from_file()
    oci.config.validate_config(config)
    comp = config["tenancy"]  # compartimento raíz
    ident = oci.identity.IdentityClient(config)
    comp_cli = oci.core.ComputeClient(config)
    red = oci.core.VirtualNetworkClient(config)

    ad = ident.list_availability_domains(comp).data[0].name
    img = imagen_ubuntu(comp_cli, comp)
    anotar(f"conectado a Oracle · región {config['region']} · {ad} · imagen {img.display_name}")

    existente = por_nombre(comp_cli.list_instances(comp).data, NOMBRE)
    if existente:
        anotar(f"ya existe {NOMBRE} ({existente.lifecycle_state}): no se crea otro")
        if not a.solo_revisar:
            terminar(comp_cli, red, comp, existente)
        return
    if a.solo_revisar:
        anotar("conexión OK; no se creó nada (--solo-revisar)")
        return
    if not a.llave_ssh:
        raise SystemExit("Falta --llave-ssh con la llave pública (.pub).")
    llave = Path(a.llave_ssh).read_text(encoding="utf-8").strip()

    sub = preparar_red(red, comp)
    no_suspender()
    fin = time.time() + LIMITE_H * 3600
    intento = 0
    while time.time() < fin:
        nucleos, ram = TAMANOS[intento % len(TAMANOS)]
        intento += 1
        # Antes de cada intento: si alguien ya lo creó (a mano o con otra copia
        # del script), no se crea un segundo servidor.
        existente = por_nombre(comp_cli.list_instances(comp).data, NOMBRE)
        if existente:
            anotar(f"ya existe {NOMBRE} ({existente.lifecycle_state}): no se crea otro")
            terminar(comp_cli, red, comp, existente)
            return
        try:
            inst = comp_cli.launch_instance(oci.core.models.LaunchInstanceDetails(
                availability_domain=ad, compartment_id=comp, display_name=NOMBRE, shape=FORMA,
                shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=nucleos, memory_in_gbs=ram),
                source_details=oci.core.models.InstanceSourceViaImageDetails(image_id=img.id),
                create_vnic_details=oci.core.models.CreateVnicDetails(subnet_id=sub.id, assign_public_ip=True),
                metadata={"ssh_authorized_keys": llave})).data
            anotar(f"intento {intento} ({nucleos} núcleos / {ram} GB): ¡ACEPTADO! esperando que arranque…")
            terminar(comp_cli, red, comp, inst)
            return
        except oci.exceptions.ServiceError as e:
            sin_lugar = "capacity" in (e.message or "").lower()
            if e.status == 429:
                motivo, espera = "demasiados pedidos seguidos", ESPERA_S * 2
            elif sin_lugar:
                motivo, espera = "sin lugar (Out of capacity)", ESPERA_S
            else:
                anotar(f"intento {intento}: ERROR {e.status} {e.code}: {e.message}")
                if e.status in (400, 401, 403, 404):
                    raise SystemExit("Error que no se arregla reintentando: revisar la configuración o los límites.")
                motivo, espera = "error temporal", ESPERA_S
            anotar(f"intento {intento} ({nucleos} núcleos / {ram} GB): {motivo}; reintento en ~{espera // 60} min")
            time.sleep(espera + random.randint(0, 30))
    anotar(f"se cumplieron {LIMITE_H} h sin lugar en Oracle: conviene pasar a otro proveedor (ver docs/DESPLIEGUE.md)")


if __name__ == "__main__":
    main()
